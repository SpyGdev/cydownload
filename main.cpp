#include "mainwindow.h"
#include "theme.h"
#include <QApplication>

int main(int argc, char *argv[])
{
    QApplication a(argc, argv);
    a.setOrganizationName("cydownload");
    a.setApplicationName("cydownload");
    Theme::applySaved();

    MainWindow w;
    w.show();

    return a.exec();
}
