#include "theme.h"

#include <QApplication>
#include <QPalette>
#include <QSettings>
#include <QStyle>
#include <QStyleFactory>
#include <QWidget>

bool Theme::s_dark = false;
bool Theme::s_ready = false;

static QString s_defaultStyleName;
static QPalette s_defaultPalette;

static const char *kDarkModeKey = "appearance/darkMode";

static QPalette darkPalette()
{
    QPalette palette;
    const QColor window(53, 53, 53);
    const QColor base(25, 25, 25);
    const QColor text(255, 255, 255);
    const QColor disabled(128, 128, 128);
    const QColor highlight(42, 130, 218);

    palette.setColor(QPalette::Window, window);
    palette.setColor(QPalette::WindowText, text);
    palette.setColor(QPalette::Base, base);
    palette.setColor(QPalette::AlternateBase, window);
    palette.setColor(QPalette::ToolTipBase, window);
    palette.setColor(QPalette::ToolTipText, text);
    palette.setColor(QPalette::Text, text);
    palette.setColor(QPalette::Button, window);
    palette.setColor(QPalette::ButtonText, text);
    palette.setColor(QPalette::BrightText, Qt::red);
    palette.setColor(QPalette::Link, highlight);
    palette.setColor(QPalette::Highlight, highlight);
    palette.setColor(QPalette::HighlightedText, Qt::black);
    palette.setColor(QPalette::Light, QColor(80, 80, 80));
    palette.setColor(QPalette::Midlight, QColor(64, 64, 64));
    palette.setColor(QPalette::Dark, QColor(35, 35, 35));
    palette.setColor(QPalette::Mid, QColor(45, 45, 45));
    palette.setColor(QPalette::Shadow, QColor(20, 20, 20));

    palette.setColor(QPalette::Disabled, QPalette::Text, disabled);
    palette.setColor(QPalette::Disabled, QPalette::WindowText, disabled);
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, disabled);
    palette.setColor(QPalette::Disabled, QPalette::Highlight, QColor(80, 80, 80));
    palette.setColor(QPalette::Disabled, QPalette::HighlightedText, disabled);
    palette.setColor(QPalette::Disabled, QPalette::Base, QColor(35, 35, 35));

    return palette;
}

static QString darkStyleSheet()
{
    return QString(
        "QToolTip {"
        "  color: #ffffff;"
        "  background-color: #353535;"
        "  border: 1px solid #767676;"
        "}"
        "QProgressBar {"
        "  border: 1px solid #555555;"
        "  border-radius: 2px;"
        "  text-align: center;"
        "  background-color: #2b2b2b;"
        "  color: #ffffff;"
        "}"
        "QProgressBar::chunk {"
        "  background-color: #2a82da;"
        "}");
}

void Theme::ensureDefaults()
{
    if (s_ready)
        return;

    s_defaultStyleName = qApp->style()->objectName();
    s_defaultPalette = qApp->palette();
    s_ready = true;
}

bool Theme::isDark()
{
    return s_dark;
}

void Theme::applySaved()
{
    QSettings settings;
    apply(settings.value(kDarkModeKey, false).toBool());
}

void Theme::apply(bool dark)
{
    ensureDefaults();

    if (dark)
    {
        qApp->setStyle(QStyleFactory::create("Fusion"));
        qApp->setPalette(darkPalette());
        qApp->setStyleSheet(darkStyleSheet());
    }
    else
    {
        QStyle *style = QStyleFactory::create(s_defaultStyleName);
        if (!style)
            style = QStyleFactory::create("Fusion");
        if (style)
            qApp->setStyle(style);
        qApp->setPalette(s_defaultPalette);
        qApp->setStyleSheet(QString());
    }

    QWidgetList widgets = qApp->allWidgets();
    for (int i = 0; i < widgets.size(); ++i)
    {
        QWidget *widget = widgets.at(i);
        widget->style()->unpolish(widget);
        widget->style()->polish(widget);
        widget->update();
    }

    s_dark = dark;
    QSettings().setValue(kDarkModeKey, dark);
}
