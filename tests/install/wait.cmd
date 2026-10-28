@rem Stays up for a few seconds, for tests/install.sh to install over. ping fails at
@rem low integrity (ICMP), so the app's image asks for the soft sandbox.
@ping -n %1 127.0.0.1 >nul
