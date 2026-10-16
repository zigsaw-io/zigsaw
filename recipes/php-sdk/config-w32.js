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
  headers: [], // PHP_INSTALL_HEADERS: { file, dest } under include\
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

// The libraries PHP's build is linked with, as its deps packages have them:
// headers in include\, import libraries in lib\ (see recipes/php-sdk.json).
// confutils.js calls this directory PHP_PHP_BUILD.
const depsDir = path.join(devDir, "deps");

// What a recipe's earlier modules installed into the build's prefix: the
// libraries an extension needs that PHP doesn't ship, built first. They come
// before PHP's, as php.net's own builds find everything in PHP_PHP_BUILD.
const prefixDir = process.env.PREFIX && fs.existsSync(process.env.PREFIX) ? process.env.PREFIX : null;

// Directories a pattern names: confutils globs the last part ("libxml2*").
function globDirs(p) {
  p = resolve(p);
  if (!/[*?]/.test(path.basename(p))) return [p];
  const parent = path.dirname(p);
  const re = new RegExp("^" + path.basename(p).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$", "i");
  if (!fs.existsSync(parent)) return [];
  return fs.readdirSync(parent).filter((n) => re.test(n)).sort().map((n) => path.join(parent, n));
}

// Other extensions built by php-ext that this one may depend on: those whose
// directory a PHP_EXT_<NAME> variable names, as their images' env does in
// builds that have them as SDKs. php-ext put their headers in include\ext
// and their import library, lib\php_<name>.lib, there.
const peers = Object.keys(process.env)
  .map((k) => k.match(/^PHP_EXT_([A-Z0-9_]+)$/i))
  .filter(Boolean)
  .map((m) => ({ name: m[1].toLowerCase(), dir: process.env[m[0]] }))
  .filter((p) => fs.existsSync(path.join(p.dir, "lib", "php_" + p.name + ".lib")));

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
  globDirs,
  depsDir: fs.existsSync(depsDir) ? depsDir : "no",
  // Include directories CHECK_HEADER_ADD_INCLUDE searches after its own:
  // PHP's, then the build's prefix, PHP's libraries', then Windows'.
  includeDirs: [
    path.join(devDir, "include"),
    path.join(devDir, "include", "main"),
    path.join(devDir, "include", "Zend"),
    path.join(devDir, "include", "TSRM"),
    path.join(devDir, "include", "ext"),
  ]
    .concat(prefixDir ? [path.join(prefixDir, "include")] : [])
    .concat([path.join(depsDir, "include")])
    .concat(peers.map((p) => path.join(p.dir, "include", "ext", p.name)))
    .concat((process.env.PHP_EXT_SYSTEM_INCLUDE || "").split(";").filter(Boolean)),
  // Library directories CHECK_LIB searches after its own.
  libDirs: (prefixDir ? [path.join(prefixDir, "lib")] : []).concat([path.join(depsDir, "lib")]),
  peers,
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
  PHP_PHP_BUILD = __host.depsDir, PHP_EXTRA_INCLUDES = "", PHP_EXTRA_LIBS = "", PHP_SECURITY_FLAGS = "yes",
  X64 = true, TARGET_ARCH = "x64", HOST_ARCH = "x64", VS_TOOLSET = false, CLANG_TOOLSET = true, ICC_TOOLSET = false,
  VCVERS = 1944, COMPILER_NAME_LONG = "zig cc", COMPILER_NAME_SHORT = "clang", PHP_DIR = "";
var PHP_VERSION = __host.version.major, PHP_MINOR_VERSION = __host.version.minor,
  PHP_RELEASE_VERSION = __host.version.release, PHP_EXTRA_VERSION = "";
var configure_module_dirname = ".";
var configure_args = [], configure_hdr = {}, extensions_enabled = [];
var __first_arg = true;
// As configure defines them for PHP's NTS build; igbinary tells PHP's
// version by them.
DEFINE("PHPDLL", "php" + PHP_VERSION + ".dll");
DEFINE("PHPLIB", "php" + PHP_VERSION + ".lib");

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

// Libraries PHP's build links into php8.dll, which exports their functions:
// an extension gets them from php8.lib, as its own build gets them from the
// static library, whenever PHP has the extension built in.
var __php8_libs = {
  "zlib_a.lib": "ZLIB", "zlib.lib": "ZLIB",
  "libxml2_a.lib": "LIBXML", "libxml2_a_dll.lib": "LIBXML", "libxml2.lib": "LIBXML",
  "libiconv_a.lib": "ICONV", "libiconv.lib": "ICONV", "iconv_a.lib": "ICONV", "iconv.lib": "ICONV",
};
function __builtin(ext) {
  var v = globalThis["PHP_" + ext];
  return v != null && v !== false && v != "no" && !globalThis["PHP_" + ext + "_SHARED"];
}

// The directories a ;-separated list names, patterns expanded.
function __dirs(list) {
  var out = [], parts = list ? String(list).split(";") : [];
  for (var i = 0; i < parts.length; i++) if (parts[i]) out = out.concat(__host.globDirs(parts[i]));
  return out;
}

// As confutils': the given directories, the package's own under
// PHP_PHP_BUILD (common_name, or the target), then the libraries' lib\;
// in each, the file itself or under lib\, libs\ or Release\. Returns where
// it found the library, as confutils' does (yaml's config.w32 reads its
// name), or false.
function CHECK_LIB(libnames, target, path_to_check, common_name) {
  if (common_name == null && target != null) common_name = target;
  var paths = path_to_check ? String(path_to_check) : "";
  if (common_name != null && PHP_PHP_BUILD != "no")
    paths += ";" + PHP_PHP_BUILD + "\\" + common_name + "*;" + PHP_PHP_BUILD + "\\lib\\" + common_name + "*";
  var dirs = __dirs(paths).concat(__host.libDirs);
  var names = String(libnames).split(";");
  var T = target ? "_" + target.toUpperCase() : "";
  for (var i = 0; i < names.length; i++) {
    if (!names[i]) continue;
    var lib = names[i].replace(/\.lib$/i, "").toLowerCase();
    var php8 = __php8_libs[names[i].toLowerCase()];
    if (php8 && __builtin(php8)) {
      __host.note("Checking for library " + libnames + " ... php8.lib (PHP has " + php8.toLowerCase() + " built in)");
      return "php8.lib";
    }
    var found = __host.systemLibs.has(lib) ? names[i] : false;
    for (var j = 0; j < dirs.length && !found; j++) {
      var subs = ["", "/lib", "/libs", "/Release"];
      for (var k = 0; k < subs.length && !found; k++) {
        var d = dirs[j] + subs[k];
        if (__host.isFile(d + "/" + names[i])) found = d + "\\" + names[i];
        else if (__host.isFile(d + "/lib" + lib + ".a")) found = d + "\\lib" + lib + ".a";
        if (found) ADD_FLAG("LDFLAGS" + T, "/libpath:" + d);
      }
    }
    if (found) {
      __host.note("Checking for library " + libnames + " ... " + names[i]);
      ADD_FLAG("LIBS" + T, names[i]);
      return found;
    }
  }
  __host.note("Checking for library " + libnames + " ... <not found>");
  return false;
}

function __search(header, paths) {
  var dirs = __dirs(paths).concat(__host.includeDirs);
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

// Headers for other extensions to build with, which php-ext copies into
// include\<dir>, keeping each one's path under the extension's directory.
function PHP_INSTALL_HEADERS(dir, headers_list) {
  var list = trim(headers_list).split(/\s+/).sort();
  dir = String(dir).replace(/\\/g, "/").replace(/\/?$/, "/");
  for (var i = 0; i < list.length; i++) {
    if (!list[i]) continue;
    var src = list[i].replace(/\\/g, "/");
    var file = (configure_module_dirname + "/" + src).replace(/\\/g, "/");
    if (!__host.isFile(file)) { __host.note("php-ext: leaving out the header " + src + ", which isn't there"); continue; }
    __host.out.headers.push({ file: file, dest: dir + src });
  }
}
// What a phpize build doesn't need: dist files.
function ADD_DIST_FILE() {}
function ADD_MAKEFILE_FRAGMENT(f) { __host.note("php-ext: leaving out the Makefile fragment " + f); }
function ADD_DEF_FILE(f) { __host.note("php-ext: leaving out the .def file " + f); }
// As confutils': zlib is PHP's own when it's built in; OpenSSL 1.1 or later
// is 2.
function SETUP_ZLIB_LIB(target, path_to_check) {
  return __builtin("ZLIB") || CHECK_LIB("zlib_a.lib;zlib.lib", target, path_to_check);
}
function SETUP_OPENSSL(target, path_to_check, common_name, use_env, add_dir_part, add_to_flag_only) {
  var cflags = "CFLAGS_" + target.toUpperCase();
  if (CHECK_LIB("libcrypto.lib", target, path_to_check) &&
      CHECK_LIB("libssl.lib", target, path_to_check) &&
      CHECK_LIB("crypt32.lib", target, path_to_check, common_name) &&
      CHECK_HEADER_ADD_INCLUDE("openssl/ssl.h", cflags, path_to_check, use_env, add_dir_part, add_to_flag_only))
    return 2;
  return 0;
}
function SETUP_SQLITE3(target, path_to_check, shared) {
  var cflags = "CFLAGS_" + target.toUpperCase();
  return CHECK_LIB(shared ? "libsqlite3.lib;libsqlite3_a.lib" : "libsqlite3_a.lib;libsqlite3.lib", target, path_to_check) &&
    CHECK_HEADER_ADD_INCLUDE("sqlite3.h", cflags) &&
    CHECK_HEADER_ADD_INCLUDE("sqlite3ext.h", cflags);
}

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
  // The other extensions found are there as DLLs, as PHP's own shared ones.
  vm.runInContext(String.raw`
    for (var __i = 0; __i < __host.peers.length; __i++) {
      var __p = __host.peers[__i], __N = __p.name.toUpperCase();
      if (globalThis["PHP_" + __N] != null) continue;
      globalThis["PHP_" + __N] = "yes";
      globalThis["PHP_" + __N + "_SHARED"] = true;
      ADD_FLAG("CFLAGS", '/I "' + __p.dir + '\\include\\ext"');
      ADD_FLAG("LDFLAGS", "/libpath:" + __p.dir + "\\lib");
      __host.note("php-ext: " + __p.name + " is there, in " + __p.dir);
    }`, context, { filename: "config-w32.js" });
  vm.runInContext(fs.readFileSync(configW32, "latin1"), context, { filename: configW32 });
} catch (e) {
  if (e instanceof ReferenceError) host.fail(`${configW32} uses ${e.message.replace(/ is not defined$/, "")}, which php-ext doesn't provide`);
  host.fail(`${configW32}: ${e.message}`);
}
if (out.extensions.length === 0) host.fail(`${configW32} enables no extension (pass --enable-<name> or --with-<name>)`);
process.stdout.write(JSON.stringify(out, null, 1) + "\n");
