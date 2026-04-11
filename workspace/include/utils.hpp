#pragma once

#include <string>
#include <map>
#include <vector>
#include <stdexcept>
#include <cstdlib>

class ArgParser {
private:
    struct Arg {
        std::string short_form;
        std::string long_form;
        bool has_value;
        std::string help;
    };

    std::vector<Arg> registered_args;
    std::map<std::string, std::string> parsed_values;
    std::vector<std::string> positional;
    bool valid = true;

public:
    ArgParser() = default;

    void add(const std::string& short_form, const std::string& long_form,
        bool has_value = false, const std::string& help = "") {
        registered_args.push_back({ short_form, long_form, has_value, help });
    }

    void parse(int argc, char* argv[]) {
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];

            if (arg == "--help" || arg == "-h") {
                print_help(argv[0]);
                exit(0);
            }

            bool found = false;
            for (const auto& reg : registered_args) {
                if ((arg == reg.short_form || arg == reg.long_form)) {
                    found = true;
                    if (reg.has_value) {
                        if (i + 1 >= argc) {
                            std::cerr << "ERROR: " << arg << " requires a value\n";
                            valid = false;
                            return;
                        }
                        parsed_values[reg.long_form] = argv[++i];
                    }
                    else {
                        parsed_values[reg.long_form] = "true";
                    }
                    break;
                }
            }

            if (!found) {
                positional.push_back(arg);
            }
        }
    }

    bool has(const std::string& name) const {
        return parsed_values.find(name) != parsed_values.end();
    }

    template <typename T>
    T get(const std::string& name, const T& default_value = T()) const {
        auto it = parsed_values.find(name);
        if (it == parsed_values.end()) {
            return default_value;
        }

        const std::string& val = it->second;

        if constexpr (std::is_same_v<T, std::string>) {
            return val;
        }
        else if constexpr (std::is_same_v<T, int>) {
            return std::stoi(val);
        }
        else if constexpr (std::is_same_v<T, double>) {
            return std::stod(val);
        }
        else if constexpr (std::is_same_v<T, bool>) {
            return val == "true" || val == "1" || val == "yes";
        }
        return default_value;
    }

    std::vector<std::string> get_positional() const {
        return positional;
    }

    bool is_valid() const {
        return valid;
    }

    void print_help(const char* program_name = "test_detector") const {
        std::cout << "Usage: " << program_name << " [options]\n\n";
        std::cout << "Options:\n";
        for (const auto& arg : registered_args) {
            std::string names;
            if (!arg.short_form.empty()) {
                names += arg.short_form;
                if (!arg.long_form.empty()) names += ", ";
            }
            if (!arg.long_form.empty()) {
                names += arg.long_form;
            }
            if (arg.has_value) {
                names += " VALUE";
            }
            printf("  %-30s %s\n", names.c_str(), arg.help.c_str());
        }
        std::cout << "  -h, --help                     Show this help message\n";
    }
};
