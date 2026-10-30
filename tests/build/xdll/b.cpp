#define B_BUILD
#include "shared.h"

Derived::~Derived() = default;
int Derived::id() const { return 2; }

Base *b_new_derived() { return new Derived; }

int b_catch_aerror() {
    try {
        a_throw_aerror();
    } catch (const AError &e) {
        return e.code();
    } catch (...) {
    }
    return 0;
}

int b_catch_header() {
    try {
        a_throw_header();
    } catch (const HeaderError &) {
        return 1;
    } catch (...) {
    }
    return 0;
}

int b_catch_through_a() {
    try {
        a_call([] { throw HeaderError("from b, through a"); });
    } catch (const HeaderError &) {
        return 1;
    } catch (...) {
    }
    return 0;
}

void b_free_string(std::string *s) { delete s; }
void b_free_vector(std::vector<int> *v) { delete v; }

static struct Init {
    int value;
    Init() : value(9) {}
} init;
int b_static_init() { return init.value; }
