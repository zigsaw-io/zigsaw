// What two DLLs and a program share: each links its own copy of libc++,
// libc++abi and libunwind, and C++ still has to work across them.
#pragma once
#include <exception>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef A_BUILD
#define A_API __declspec(dllexport)
#else
#define A_API __declspec(dllimport)
#endif
#ifdef B_BUILD
#define B_API __declspec(dllexport)
#else
#define B_API __declspec(dllimport)
#endif

// Defined in a.dll, its vtable and type information there.
class A_API AError : public std::runtime_error {
public:
    explicit AError(const std::string &what);
    ~AError() override;
    int code() const;
};

class A_API Base {
public:
    virtual ~Base();
    virtual int id() const;
};

// Header only: every DLL that uses them has its own type information.
struct HeaderError : std::runtime_error {
    explicit HeaderError(const std::string &what) : std::runtime_error(what) {}
};

struct HBase {
    virtual ~HBase() = default;
    virtual int id() const { return 1; }
};

struct HDerived : HBase {
    int id() const override { return 2; }
};

A_API void a_throw_aerror();
A_API void a_throw_header();
A_API void a_call(const std::function<void()> &f);
A_API std::exception_ptr a_captured();
A_API HBase *a_new_hderived();
A_API std::string *a_new_string();
A_API std::vector<int> *a_new_vector();
A_API std::function<int(int)> a_adder(int n);
A_API int a_apply(const std::function<int(int)> &f, int x);
A_API void a_tls_set(int v);
A_API int a_tls_get();
A_API int a_static_init();

class B_API Derived : public Base {
public:
    ~Derived() override;
    int id() const override;
};

B_API Base *b_new_derived();
B_API int b_catch_aerror();
B_API int b_catch_header();
B_API int b_catch_through_a();
B_API void b_free_string(std::string *s);
B_API void b_free_vector(std::vector<int> *v);
B_API int b_static_init();
