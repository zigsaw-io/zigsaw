#define A_BUILD
#include "shared.h"

AError::AError(const std::string &what) : std::runtime_error(what) {}
AError::~AError() = default;
int AError::code() const { return 42; }

Base::~Base() = default;
int Base::id() const { return 1; }

void a_throw_aerror() { throw AError("from a"); }
void a_throw_header() { throw HeaderError("header-only, from a"); }

// Its frame is between the thrower and the catcher.
void a_call(const std::function<void()> &f) {
    std::string in_frame = "unwound";
    f();
}

std::exception_ptr a_captured() {
    try {
        throw AError("captured in a");
    } catch (...) {
        return std::current_exception();
    }
}

HBase *a_new_hderived() { return new HDerived; }
std::string *a_new_string() { return new std::string("made in a"); }
std::vector<int> *a_new_vector() { return new std::vector<int>{1, 2, 3}; }
std::function<int(int)> a_adder(int n) {
    return [n](int x) { return x + n; };
}
int a_apply(const std::function<int(int)> &f, int x) { return f(x); }

static thread_local int tls = 0;
void a_tls_set(int v) { tls = v; }
int a_tls_get() { return tls; }

static struct Init {
    int value;
    Init() : value(7) {}
} init;
int a_static_init() { return init.value; }
