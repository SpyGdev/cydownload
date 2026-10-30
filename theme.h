#ifndef THEME_H
#define THEME_H

class Theme
{
public:
    static bool isDark();
    static void applySaved();
    static void apply(bool dark);

private:
    static void ensureDefaults();

    static bool s_dark;
    static bool s_ready;
};

#endif // THEME_H
