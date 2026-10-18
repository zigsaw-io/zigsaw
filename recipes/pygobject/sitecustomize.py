"""PyGObject's runtime for zigsaw: Python in AppContainers.

A process in an AppContainer may create named pipes only in its own
namespace, \\\\.\\pipe\\LOCAL\\. multiprocessing names its pipes
\\\\.\\pipe\\pyc-..., which Windows refuses there, so a Queue, Pipe or Pool
fails with PermissionError under zigsaw's --sandbox=appcontainer (Meld
compares files in such a worker). Names under LOCAL\\ work outside
AppContainers too. This moves them there once multiprocessing.connection is
imported, rather than importing it in every run.

Since Python 3.13, os.mkdir(path, 0o700) gives the directory a protected ACL
of its own (owner, SYSTEM, Administrators), which leaves out the container:
an AppContainer makes the directory and then can't create anything in it.
tempfile.mkdtemp and TemporaryDirectory make theirs so (Gaphor's auto layout
runs Graphviz in one). In an AppContainer, such a directory takes the ACL of
where it's made instead, which zigsaw's grants limit to you and the
container already.
"""
import sys

if sys.platform == "win32":
    import importlib.machinery
    import os

    _mkdir = os.mkdir
    _in_appcontainer = None

    def _appcontainer():
        global _in_appcontainer
        if _in_appcontainer is None:
            import ctypes
            from ctypes import wintypes

            advapi32 = ctypes.WinDLL("advapi32")
            advapi32.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
            flag = wintypes.DWORD(0)
            size = wintypes.DWORD(0)
            # The current process's token (pseudo-handle -4), TokenIsAppContainer (29).
            ok = advapi32.GetTokenInformation(-4, 29, ctypes.byref(flag), 4, ctypes.byref(size))
            _in_appcontainer = bool(ok and flag.value)
        return _in_appcontainer

    def mkdir(path, mode=0o777, *, dir_fd=None):
        if mode == 0o700 and _appcontainer():
            mode = 0o777
        return _mkdir(path, mode, dir_fd=dir_fd)

    mkdir.__doc__ = _mkdir.__doc__
    os.mkdir = mkdir

    class _LocalPipes:
        def find_spec(self, name, path, target=None):
            if name != "multiprocessing.connection":
                return None
            spec = importlib.machinery.PathFinder.find_spec(name, path)
            if spec is None or spec.loader is None:
                return spec
            exec_module = spec.loader.exec_module

            def exec_and_move_pipes(module):
                exec_module(module)
                original = module.arbitrary_address

                def arbitrary_address(family):
                    address = original(family)
                    if family == "AF_PIPE":
                        address = address.replace("\\\\.\\pipe\\", "\\\\.\\pipe\\LOCAL\\", 1)
                    return address

                module.arbitrary_address = arbitrary_address

            spec.loader.exec_module = exec_and_move_pipes
            return spec

    sys.meta_path.insert(0, _LocalPipes())
