// Prints "ok <check>" or "FAILED <check>" for each, and exits with the
// number that failed.
#include "shared.h"
#include <cstdio>
#include <thread>
#include <typeinfo>

static int failed = 0;

static void check(const char *name, bool ok) {
    std::printf("%s %s\n", ok ? "ok" : "FAILED", name);
    if (!ok) failed++;
}

template <class F> static bool catches(F f) {
    try {
        return f();
    } catch (...) {
        return false;
    }
}

int main() {
    check("a DLL's exception caught by its type in the program", catches([] {
        try {
            a_throw_aerror();
        } catch (const AError &e) {
            return e.code() == 42;
        }
        return false;
    }));
    check("a DLL's exception caught by its type in another DLL", b_catch_aerror() == 42);
    check("a DLL's exception caught as std::runtime_error", catches([] {
        try {
            a_throw_aerror();
        } catch (const std::runtime_error &e) {
            return std::string(e.what()) == "from a";
        }
        return false;
    }));
    check("a header-only exception from a DLL caught in the program", catches([] {
        try {
            a_throw_header();
        } catch (const HeaderError &) {
            return true;
        }
        return false;
    }));
    check("a header-only exception from a DLL caught in another DLL", b_catch_header() == 1);
    check("the program's exception unwound through a DLL's frame", catches([] {
        try {
            a_call([] { throw HeaderError("from the program"); });
        } catch (const HeaderError &) {
            return true;
        }
        return false;
    }));
    check("a DLL's exception unwound through another DLL's frame", b_catch_through_a() == 1);
    check("an exception_ptr made in a DLL rethrown in the program", catches([] {
        try {
            std::rethrow_exception(a_captured());
        } catch (const AError &e) {
            return e.code() == 42;
        }
        return false;
    }));

    Base *d = b_new_derived();
    check("dynamic_cast to a class whose vtable is in another DLL", dynamic_cast<Derived *>(d) != nullptr);
    check("typeid of a class whose vtable is in another DLL", typeid(*d) == typeid(Derived));
    check("a virtual call across DLLs", d->id() == 2);
    delete d;
    HBase *h = a_new_hderived();
    check("dynamic_cast to a header-only class made in a DLL", dynamic_cast<HDerived *>(h) != nullptr);
    check("typeid of a header-only class made in a DLL", typeid(*h) == typeid(HDerived));
    delete h;

    std::string *s = a_new_string();
    s->append(1000, 'x');
    check("a string made in a DLL, grown in the program", s->size() == 1009);
    b_free_string(s);
    std::vector<int> *v = a_new_vector();
    for (int i = 0; i < 1000; i++) v->push_back(i);
    check("a vector made in a DLL, grown in the program", v->size() == 1003);
    b_free_vector(v);

    check("a DLL's std::function called in the program", a_adder(40)(2) == 42);
    check("the program's std::function called in a DLL", a_apply([](int x) { return x * 2; }, 21) == 42);

    a_tls_set(5);
    int other = -1;
    std::thread t([&] { other = a_tls_get(); });
    t.join();
    check("a DLL's thread_local is per thread", a_tls_get() == 5 && other == 0);
    check("both DLLs' static initialisers ran", a_static_init() == 7 && b_static_init() == 9);
    return failed;
}
