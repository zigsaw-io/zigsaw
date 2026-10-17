"""PyGObject's runtime for zigsaw: Python's multiprocessing in AppContainers.

A process in an AppContainer may create named pipes only in its own
namespace, \\\\.\\pipe\\LOCAL\\. multiprocessing names its pipes
\\\\.\\pipe\\pyc-..., which Windows refuses there, so a Queue, Pipe or Pool
fails with PermissionError under zigsaw's --sandbox=appcontainer (Meld
compares files in such a worker). Names under LOCAL\\ work outside
AppContainers too. This moves them there once multiprocessing.connection is
imported, rather than importing it in every run.
"""
import sys

if sys.platform == "win32":
    import importlib.machinery

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
