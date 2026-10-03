// C++ without its runtime, so cc links it with the C program.
template <typename T> T twice(T x) { return x + x; }

extern "C" int twice_int(int x) { return twice(x); }
