// The snes9x core (static library SNESCore) is C++, but a static library carries no link
// dependencies of its own, and the app target is otherwise Swift + C. Having one C++
// translation unit in the app target makes Xcode link the C++ standard library (libc++),
// which snes9x needs (std::vector, std::string, exceptions). Equivalent to adding
// OTHER_LDFLAGS = -lc++ to the Duomulator target.
#include <vector>

extern "C" unsigned long duo_cxx_runtime_linked(void) {
    // Referencing the library from here keeps the dependency explicit.
    return std::vector<int>(1).size();
}
