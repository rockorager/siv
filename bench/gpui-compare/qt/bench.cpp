// The Qt side of bench/gpui-compare: one program, one scenario per run.
//
//     qt-bench idle|gallery|list|text|grid|typing
//
// Qt Quick with Qt Quick Controls (Fusion), rendered by the scene graph
// on Vulkan (run.py sets QSG_RHI_BACKEND=vulkan): Qt's GPU toolkit. Qt
// Widgets paints with its raster engine on the CPU even on a GPU, so it
// is not the Qt this bench compares. The scenes are in bench.qml, next to
// the program (build.sh copies it), so that Qt's QML disk cache keeps
// its compiled form between runs as an installed application's would.
// README.md lists the differences that remain.
#include <QFont>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QStyleHints>

#include <cstring>

#include "../common/doc.h"

int main(int argc, char **argv) {
	const char *scenario = argc > 1 ? argv[1] : "idle";
	QGuiApplication app(argc, argv);
	QGuiApplication::setDesktopFileName("qt-bench");
	QGuiApplication::styleHints()->setCursorFlashTime(0); // a steady caret, as in the others
	QGuiApplication::setFont(QFont(BENCH_FONT, 11));
	QQuickStyle::setStyle("Fusion");
	QString doc;
	size_t len = 0;
	if (strcmp(scenario, "text") == 0 || strcmp(scenario, "typing") == 0) {
		char *text = doc_generate(strcmp(scenario, "text") == 0 ? DOC_LARGE_PARAGRAPHS : DOC_SMALL_PARAGRAPHS, &len);
		doc = QString::fromUtf8(text, (qsizetype)len);
		free(text);
	} else if (strcmp(scenario, "idle") != 0 && strcmp(scenario, "gallery") != 0 && strcmp(scenario, "list") != 0 &&
	           strcmp(scenario, "grid") != 0) {
		fprintf(stderr, "unknown scenario %s\n", scenario);
		return 2;
	}
	QQmlApplicationEngine engine;
	engine.rootContext()->setContextProperty("scenario", QString(scenario));
	engine.rootContext()->setContextProperty("doc", doc);
	engine.rootContext()->setContextProperty("needle", QString(DOC_NEEDLE));
	engine.load(QCoreApplication::applicationDirPath() + "/qt-bench.qml");
	if (engine.rootObjects().isEmpty()) return 1;
	return app.exec();
}
