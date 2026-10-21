// A Qt app for tests/qt.sh: says where Qt finds its plugins and
// translations, where QSettings and QStandardPaths keep files, which image
// formats and TLS backends it has, translates a string with qtbase's French
// catalogue, opens a window, waits for it to be painted, and quits.
#include <QApplication>
#include <QImageReader>
#include <QLabel>
#include <QLibraryInfo>
#include <QSettings>
#include <QSslSocket>
#include <QStandardPaths>
#include <QTimer>
#include <QTranslator>
#include <cstdio>

static void say(const QString &line) {
    std::printf("%s\n", qUtf8Printable(line));
    std::fflush(stdout);
}

class Window : public QLabel {
public:
    using QLabel::QLabel;

protected:
    void paintEvent(QPaintEvent *event) override {
        QLabel::paintEvent(event);
        if (!painted) {
            painted = true;
            say(QStringLiteral("painted a window with %1").arg(QGuiApplication::platformName()));
            QTimer::singleShot(0, qApp, &QCoreApplication::quit);
        }
    }

private:
    bool painted = false;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("zigsaw"));
    app.setApplicationName(QStringLiteral("hello-qt"));
    say(QStringLiteral("Qt %1").arg(QString::fromLatin1(qVersion())));
    say(QStringLiteral("prefix %1").arg(QLibraryInfo::path(QLibraryInfo::PrefixPath)));
    say(QStringLiteral("plugins %1").arg(QLibraryInfo::path(QLibraryInfo::PluginsPath)));
    say(QStringLiteral("translations %1").arg(QLibraryInfo::path(QLibraryInfo::TranslationsPath)));
    say(QStringLiteral("settings %1").arg(QSettings().fileName()));
    say(QStringLiteral("app data %1").arg(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)));

    QStringList formats;
    for (const QByteArray &f : QImageReader::supportedImageFormats())
        formats << QString::fromLatin1(f);
    say(QStringLiteral("image formats %1").arg(formats.join(u' ')));
    say(QStringLiteral("tls backends %1").arg(QSslSocket::availableBackends().join(u' ')));

    QTranslator translator;
    if (translator.load(QLocale(QLocale::French), QStringLiteral("qtbase"), QStringLiteral("_"),
                        QLibraryInfo::path(QLibraryInfo::TranslationsPath)))
        app.installTranslator(&translator);
    say(QStringLiteral("Cancel in French: %1").arg(QCoreApplication::translate("QPlatformTheme", "Cancel")));

    if (app.arguments().contains(QStringLiteral("--no-window")))
        return 0;
    Window window(QStringLiteral("hello from Qt"));
    window.setWindowTitle(QStringLiteral("zigsaw"));
    window.resize(240, 80);
    window.show();
    return app.exec();
}
