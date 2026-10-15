// config-w32.js: runs a PHP extension's config.w32 the way phpize's
// configure does on Windows, with stand-ins for confutils.js's functions,
// and prints what to build as JSON for php-ext.php, which builds it with zig.
//
//   node config-w32.js <ext dir> <sdk dev dir> [--enable-foo[=...]|--with-foo[=...]|--disable-foo|--without-foo]...
//
// confutils.js writes a Makefile for nmake and MSVC; here the functions
// record sources, flags, defines and libraries instead. MSVC's flags are
// translated where zig's cc has the same meaning (/D, /I, /U, /FI) and left
// out otherwise. A function this doesn't know fails the build, naming it.
// Messages go to stderr; stdout is only the JSON.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const [extDir, devDir, ...args] = process.argv.slice(2);
if (!extDir || !devDir) {
  process.stderr.write("usage: node config-w32.js <ext dir> <sdk dev dir> [configure options]\n");
  process.exit(2);
}
const configW32 = path.join(extDir, "config.w32");
if (!fs.existsSync(configW32)) {
  process.stderr.write(`php-ext: ${configW32} doesn't exist\n`);
  process.exit(2);
}

// What config.w32 records, read by php-ext.php.
const out = {
  extensions: [], // { name, dll, zend }
  sources: [], // { file, target }
  flags: {}, // configure_subst: CFLAGS_FOO, LIBS_FOO, LDFLAGS_FOO...
  defines: {}, // AC_DEFINE: name -> value as C source
  notes: [],
};

// The configure options, as confutils' conf_process_args reads them.
const options = new Map(); // symbol -> value
let anyEnabled = false;
for (const a of args) {
  const m = a.match(/^--(enable|disable|with|without)-([A-Za-z0-9_-]+)(?:=(.*))?$/);
  if (!m) {
    process.stderr.write(`php-ext: unknown option ${a}\n`);
    process.exit(2);
  }
  const sym = m[2].toUpperCase().replace(/-/g, "_");
  const off = m[1] === "disable" || m[1] === "without";
  options.set(sym, off ? "no" : m[3] === undefined ? "yes" : m[3]);
  if (!off) anyEnabled = true;
}

function note(msg) {
  process.stderr.write(msg + "\n");
}

// Files config.w32 may look at, relative to the extension's directory.
function resolve(p) {
  return path.resolve(extDir, String(p).replace(/\\/g, "/"));
}

const host = {
  out,
  options,
  anyEnabled,
  note,
  fail(msg) {
    process.stderr.write("php-ext: " + msg + "\n");
    process.exit(3);
  },
  exists: (p) => fs.existsSync(resolve(p)),
  isFile: (p) => fs.existsSync(resolve(p)) && fs.statSync(resolve(p)).isFile(),
  isDir: (p) => fs.existsSync(resolve(p)) && fs.statSync(resolve(p)).isDirectory(),
  read: (p) => fs.readFileSync(resolve(p), "latin1"),
  // Include directories CHECK_HEADER_ADD_INCLUDE searches after its own.
  includeDirs: [
    path.join(devDir, "include"),
    path.join(devDir, "include", "main"),
    path.join(devDir, "include", "Zend"),
    path.join(devDir, "include", "TSRM"),
    path.join(devDir, "include", "ext"),
  ].concat((process.env.PHP_EXT_SYSTEM_INCLUDE || "").split(";").filter(Boolean)),
  // Windows' libraries that zig's MinGW import libraries cover, by name.
  systemLibs: new Set((process.env.PHP_EXT_SYSTEM_LIBS || "").split(";").filter(Boolean).map((s) => s.toLowerCase())),
  version: (() => {
    const h = fs.readFileSync(path.join(devDir, "include", "main", "php_version.h"), "latin1");
    const get = (n) => (h.match(new RegExp("#define " + n + " (\\d+)")) || [])[1];
    return { major: get("PHP_MAJOR_VERSION"), minor: get("PHP_MINOR_VERSION"), release: get("PHP_RELEASE_VERSION") };
  })(),
};

// The stand-ins run in config.w32's own global scope, as confutils' do in
// configure.js: they eval "PHP_" + name to read and set its variables.
const prelude = String.raw`
var MODE_PHPIZE = true, PHP_DEBUG = "no", PHP_DEBUG_PACK = "no", PHP_ZTS = "no",
  PHP_ALL_SHARED = "yes", PHP_ANALYZER = "no", PHP_SANITIZER = "no", PHP_PGI = "no", PHP_PGO = "no",
  PHP_PHP_BUILD = "no", PHP_EXTRA_INCLUDES = "", PHP_EXTRA_LIBS = "", PHP_SECURITY_FLAGS = "yes",
  X64 = true, TARGET_ARCH = "x64", HOST_ARCH = "x64", VS_TOOLSET = false, CLANG_TOOLSET = true, ICC_TOOLSET = false,
  VCVERS = 1944, COMPILER_NAME_LONG = "zig cc", COMPILER_NAME_SHORT = "clang", PHP_DIR = "";
var PHP_VERSION = __host.version.major, PHP_MINOR_VERSION = __host.version.minor,
  PHP_RELEASE_VERSION = __host.version.release, PHP_EXTRA_VERSION = "";
var configure_module_dirname = ".";
var configure_args = [], configure_hdr = {}, extensions_enabled = [];
var __first_arg = true;

function __arg(type, optname, helptext, defval) {
  var sym = optname.toUpperCase().replace(/-/g, "_");
  var val;
  if (__host.options.has(sym)) val = __host.options.get(sym);
  else if (!__host.anyEnabled && __first_arg) val = "yes";
  else val = defval;
  __first_arg = false;
  var shared = true, m;
  // As confutils' analyze_arg: "shared", "shared,val", "val,shared".
  if (val == "shared") val = "yes";
  else if (val != null && (m = String(val).match(/^shared,(.*)$/))) val = m[1];
  else if (val != null && (m = String(val).match(/^(.*),shared$/))) val = m[1];
  globalThis["PHP_" + sym] = val;
  globalThis["PHP_" + sym + "_SHARED"] = shared;
  configure_args.push({ type: type, optname: optname, symval: sym, defval: defval, argval: val });
}
function ARG_ENABLE(optname, helptext, defval) { __arg("enable", optname, helptext, defval); }
function ARG_WITH(optname, helptext, defval) { __arg("with", optname, helptext, defval); }

function trim(s) { return String(s).replace(/^\s+/, "").replace(/\s+$/, ""); }

function ADD_FLAG(name, flags, target) {
  if (target != null) name = target.toUpperCase() + "_" + name;
  flags = trim(flags);
  var cur = __host.out.flags[name];
  if (cur != null) {
    if (cur.indexOf(" " + flags) >= 0 || cur.indexOf(flags + " ") >= 0 || cur == flags) return;
    flags = cur + " " + flags;
  }
  __host.out.flags[name] = flags;
}
function DEFINE(name, value) { __host.out.flags[name] = value; }
function get_define(name) { return __host.out.flags[name] || ""; }

function AC_DEFINE(name, value, comment, quote) {
  if (quote == null) quote = true;
  if (quote && typeof value == "string") value = '"' + value.replace(/(["\\])/g, "\\$1") + '"';
  else if (typeof value != "undefined" && value.length == 0) value = '""';
  if (name in __host.out.defines) __host.note("AC_DEFINE[" + name + "]=" + value + ": is already defined to " + __host.out.defines[name]);
  else __host.out.defines[name] = String(value);
}

function ADD_SOURCES(dir, file_list, target, obj_dir) {
  if (target == null) target = "php";
  var files = trim(file_list).split(/\s+/).sort();
  for (var i = 0; i < files.length; i++) {
    if (files[i] == "") continue;
    __host.out.sources.push({ file: (dir + "/" + files[i]).replace(/\\/g, "/"), target: target.toLowerCase() });
  }
}

function EXTENSION(extname, file_list, shared, cflags, dllname, obj_dir) {
  var EXT = extname.toUpperCase();
  if (shared === false) __host.note("php-ext: " + extname + " asks to be static; building it as a DLL, as phpize does");
  globalThis["PHP_" + EXT + "_SHARED"] = true;
  __host.out.extensions.push({ name: extname, dll: dllname || "php_" + extname + ".dll", zend: false });
  extensions_enabled.push([extname, "shared", false]);
  ADD_SOURCES(configure_module_dirname, file_list, extname, obj_dir);
  ADD_FLAG("CFLAGS_" + EXT, "/D ZEND_COMPILE_DL_EXT=1 /D COMPILE_DL_" + EXT + " /D " + EXT + "_EXPORTS=1 " + (cflags || ""));
  __host.note("Enabling extension " + extname + " [shared]");
}
function ZEND_EXTENSION(extname, file_list, shared, cflags, dllname, obj_dir) {
  EXTENSION(extname, file_list, shared, cflags, dllname, obj_dir);
  __host.out.extensions[__host.out.extensions.length - 1].zend = true;
  extensions_enabled[extensions_enabled.length - 1][2] = true;
}

function ADD_EXTENSION_DEP(extname, dependson, optional) {
  var EXT = extname.toUpperCase(), DEP = dependson.toUpperCase();
  var present = globalThis["PHP_" + DEP], shared = globalThis["PHP_" + DEP + "_SHARED"];
  if (present == null || present === false || present == "no") {
    if (optional) { MESSAGE("\t" + dependson + " not found: " + dependson + " support in " + extname + " disabled"); return false; }
    ERROR("Cannot build " + extname + "; " + dependson + " not enabled");
  }
  // A shared dependency is a DLL of PHP's own build, linked through its
  // import library in the devel pack.
  if (shared) ADD_FLAG("LIBS_" + EXT, "php_" + dependson + ".lib");
  return true;
}

function CHECK_LIB(libnames, target, path_to_check, common_name) {
  var names = String(libnames).split(";");
  for (var i = 0; i < names.length; i++) {
    var lib = names[i].replace(/\.lib$/i, "").toLowerCase();
    var found = __host.systemLibs.has(lib);
    if (!found && path_to_check) {
      var dirs = String(path_to_check).split(";");
      for (var j = 0; j < dirs.length && !found; j++)
        if (dirs[j] && (__host.isFile(dirs[j] + "/" + names[i]) || __host.isFile(dirs[j] + "/lib" + lib + ".a"))) {
          found = true;
          ADD_FLAG("LDFLAGS" + (target ? "_" + target.toUpperCase() : ""), "/libpath:" + dirs[j]);
        }
    }
    if (found) {
      __host.note("Checking for library " + libnames + " ... " + names[i]);
      ADD_FLAG("LIBS" + (target ? "_" + target.toUpperCase() : ""), names[i]);
      return true;
    }
  }
  __host.note("Checking for library " + libnames + " ... <not found>");
  return false;
}

function __search(header, paths) {
  var dirs = (paths ? String(paths).split(";") : []).concat(__host.includeDirs);
  for (var i = 0; i < dirs.length; i++)
    if (dirs[i] && __host.isFile(dirs[i] + "/" + header)) return dirs[i];
  return false;
}

function CHECK_HEADER_ADD_INCLUDE(header_name, flag_name, path_to_check, use_env, add_dir_part, add_to_flag_only) {
  var p = __search(header_name, path_to_check);
  var dir_part = "";
  if (add_dir_part) dir_part = "/" + header_name.replace(/[\\/][^\\/]*$/, "");
  if (typeof p == "string") ADD_FLAG(flag_name, '/I "' + p + dir_part + '"');
  var have = p ? 1 : 0;
  var sym = header_name.toUpperCase().replace(/[\\/.\-]/g, "_");
  if (typeof add_to_flag_only == "undefined" && /^CFLAGS_(.*)$/.test(flag_name)) add_to_flag_only = true;
  if (typeof add_to_flag_only != "undefined" && have) ADD_FLAG(flag_name, "/DHAVE_" + sym + "=" + have);
  else if (have && !("HAVE_" + sym in __host.out.defines)) AC_DEFINE("HAVE_" + sym, have);
  __host.note("Checking for " + header_name + " ... " + (p ? p : "<not found>"));
  return p;
}
function CHECK_HEADER(header_name, flag_name, path_to_check) {
  return CHECK_HEADER_ADD_INCLUDE(header_name, flag_name || "CFLAGS", path_to_check, true, false, true);
}
function GREP_HEADER(header_name, regex, path_to_check) {
  var p = __search(header_name, path_to_check);
  if (!p) return false;
  return new RegExp(regex).test(__host.read(p + "/" + header_name));
}
function CHECK_FUNC_IN_HEADER(header_name, func_name, path_to_check, add_to_flag) {
  var have = GREP_HEADER(header_name, func_name, path_to_check) ? 1 : 0;
  var sym = "HAVE_" + func_name.toUpperCase();
  if (add_to_flag) ADD_FLAG(add_to_flag, "/D" + sym + "=" + have);
  else AC_DEFINE(sym, have);
  return have;
}

// What a phpize build doesn't need: headers to install, dist files.
function PHP_INSTALL_HEADERS() {}
function ADD_DIST_FILE() {}
function ADD_MAKEFILE_FRAGMENT(f) { __host.note("php-ext: leaving out the Makefile fragment " + f); }
function ADD_DEF_FILE(f) { __host.note("php-ext: leaving out the .def file " + f); }
// PHP's own build's libraries, which the devel pack doesn't have.
function SETUP_ZLIB_LIB() { return false; }
function SETUP_OPENSSL() { return 0; }
function SETUP_SQLITE3() { return false; }

function MESSAGE(msg) { __host.note("" + msg); }
function WARNING(msg) { __host.note("WARNING: " + msg); }
function ERROR(msg) { __host.fail(msg); }

function file_get_contents(p) { return __host.read(p); }
var FSO = {
  FileExists: function (p) { return __host.isFile(p); },
  FolderExists: function (p) { return __host.isDir(p); },
  GetFileName: function (p) { return String(p).replace(/^.*[\\/]/, ""); },
  GetParentFolderName: function (p) { return String(p).replace(/[\\/][^\\/]*$/, ""); },
  OpenTextFile: function (p) {
    var lines = __host.read(p).split(/\r?\n/), i = 0;
    return {
      ReadAll: function () { return lines.join("\n"); },
      ReadLine: function () { return lines[i++]; },
      get AtEndOfStream() { return i >= lines.length; },
      Close: function () {},
    };
  },
};
var STDOUT = { WriteLine: function (s) { __host.note("" + s); }, Write: function (s) { __host.note("" + s); }, WriteBlankLines: function () {} };
var STDERR = STDOUT;
var WScript = { Echo: function (s) { __host.note("" + s); }, Quit: function (c) { __host.fail("config.w32 quit with " + c); }, StdOut: STDOUT, StdErr: STDERR };
`;

const context = vm.createContext({ __host: host });
try {
  // PHP's own build: which of its extensions exist, and which are DLLs.
  const deps = path.join(devDir, "script", "ext_deps.js");
  vm.runInContext(prelude, context, { filename: "config-w32.js" });
  if (fs.existsSync(deps)) vm.runInContext(fs.readFileSync(deps, "latin1"), context, { filename: deps });
  vm.runInContext(fs.readFileSync(configW32, "latin1"), context, { filename: configW32 });
} catch (e) {
  if (e instanceof ReferenceError) host.fail(`${configW32} uses ${e.message.replace(/ is not defined$/, "")}, which php-ext doesn't provide`);
  host.fail(`${configW32}: ${e.message}`);
}
if (out.extensions.length === 0) host.fail(`${configW32} enables no extension (pass --enable-<name> or --with-<name>)`);
process.stdout.write(JSON.stringify(out, null, 1) + "\n");
