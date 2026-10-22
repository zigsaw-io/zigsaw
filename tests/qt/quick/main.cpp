// A Qt Quick app for tests/qt.sh: says where Qt finds QML modules, loads a
// window of Qt Quick Controls from its own QML module, waits for the scene
// graph to draw a frame, reads the frame back, and says which graphics API
// drew it, the Controls style, and the colour in the window's corner (the
// window's own, #3a7bd5); then quits.
#include <QGuiApplication>
#include <QImage>
#include <QLibraryInfo>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QTimer>
#include <cstdio>

static void say(const QString &line) {
    std::printf("%s\n", qUtf8Printable(line));
    std::fflush(stdout);
}

static QString api(QSGRendererInterface::GraphicsApi a) {
    switch (a) {
    case QSGRendererInterface::Software: return QStringLiteral("software");
    case QSGRendererInterface::OpenGL: return QStringLiteral("OpenGL");
    case QSGRendererInterface::Direct3D11: return QStringLiteral("Direct3D11");
    case QSGRendererInterface::Direct3D12: return QStringLiteral("Direct3D12");
    case QSGRendererInterface::Vulkan: return QStringLiteral("Vulkan");
    default: return QStringLiteral("API %1").arg(int(a));
    }
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    say(QStringLiteral("Qt %1").arg(QString::fromLatin1(qVersion())));
    say(QStringLiteral("qml %1").arg(QLibraryInfo::path(QLibraryInfo::QmlImportsPath)));

    QQmlApplicationEngine engine;
    engine.loadFromModule("Hello", "Main");
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().value(0));
    if (!window) {
        say(QStringLiteral("no window"));
        return 1;
    }
    say(QStringLiteral("style %1").arg(QQuickStyle::name()));
    bool drawn = false;
    QObject::connect(window, &QQuickWindow::frameSwapped, &app, [&] {
        if (drawn)
            return;
        drawn = true;
        QTimer::singleShot(0, &app, [window] {
            const QImage frame = window->grabWindow();
            say(QStringLiteral("drew a frame with %1, corner %2")
                    .arg(api(window->rendererInterface()->graphicsApi()),
                         frame.isNull() ? QStringLiteral("none") : frame.pixelColor(4, 4).name()));
            QCoreApplication::quit();
        });
    });
    return app.exec();
}
