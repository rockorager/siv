// The scenes of qt-bench (bench.cpp), in Qt Quick Controls' stock types:
// Button, a Menu in its own xdg_popup (popupType: Popup.Window), TextField,
// CheckBox, ListView for the 50 items and the 100,000 rows, TextArea in a
// Flickable for the documents, and OpacityAnimator for the grid. Sizes
// and content match siv/bench.c.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
	id: window
	width: 1280
	height: 800
	visible: true
	title: "bench " + scenario

	Loader {
		anchors.fill: parent
		focus: true
		sourceComponent: ({ idle: idle, gallery: gallery, list: list, text: editor, typing: editor, grid: grid })[scenario]
	}

	Component {
		id: idle
		Item {
			Label { x: 24; y: 24; text: "Idle window" }
		}
	}

	Component {
		id: gallery
		Item {
		function setStatus(what) { status.text = "Last action: " + what }
		ColumnLayout {
			x: 24
			y: 24
			spacing: 14
			Label {
				text: "Widget gallery"
				font.pointSize: Qt.application.font.pointSize * 1.5
				font.bold: true
			}
			RowLayout {
				spacing: 8
				Button { text: "Default"; implicitHeight: 32; onClicked: setStatus(text) }
				Button { text: "Primary"; implicitHeight: 32; highlighted: true; onClicked: setStatus(text) }
				Button { text: "Disabled"; implicitHeight: 32; enabled: false }
				Button {
					id: menuButton
					text: "Menu"
					implicitHeight: 32
					onClicked: menu.open()
					Menu {
						id: menu
						y: menuButton.height
						popupType: Popup.Window
						Repeater {
							model: ["New", "Open", "Save", "Save As", "Close", "Quit"]
							MenuItem { text: modelData; onTriggered: setStatus(modelData) }
						}
					}
				}
			}
			TextField {
				placeholderText: "Type here"
				Layout.preferredWidth: 320
				Layout.preferredHeight: 32
				focus: true
			}
			CheckBox { text: "Enable feature"; onToggled: setStatus("Toggled") }
			Frame {
				padding: 1
				Layout.preferredWidth: 320
				Layout.preferredHeight: 320
				ListView {
					id: items
					anchors.fill: parent
					clip: true
					model: 50
					currentIndex: -1
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ScrollBar {}
					delegate: ItemDelegate {
						width: ListView.view.width
						height: 32
						text: "Item " + (index + 1)
						highlighted: ListView.isCurrentItem
						onClicked: { items.currentIndex = index; setStatus(text) }
					}
				}
			}
			Label { id: status; text: "Last action: none"; color: "#71717a" }
		}
		}
	}

	Component {
		id: list
		ListView {
			clip: true
			model: 100000
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ScrollBar {}
			delegate: Item {
				width: ListView.view.width
				height: 28
				Label { x: 6; anchors.verticalCenter: parent.verticalCenter; text: "Row " + (index + 1) }
				Label {
					x: 118
					anchors.verticalCenter: parent.verticalCenter
					text: "Description of row " + (index + 1) + " with a few more words"
					color: "#71717a"
				}
			}
		}
	}

	Component {
		id: editor
		// TextEdit's documented idiom for a caret that stays in view: the
		// Flickable follows cursorRectangle (TextArea alone does not).
		Flickable {
			id: flick
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ScrollBar {}
			function ensureVisible(r) {
				if (contentY >= r.y) contentY = r.y
				else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
			}
			TextArea.flickable: TextArea {
				id: area
				text: doc
				textFormat: TextEdit.PlainText
				wrapMode: TextEdit.Wrap
				padding: 24
				focus: true
				background: null
				onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
				// F3 finds the needle after the caret (from the start again
				// past the last) and selects it, which shows it.
				Keys.onPressed: (event) => {
					if (event.key !== Qt.Key_F3) return
					event.accepted = true
					let at = area.text.indexOf(needle, area.cursorPosition)
					if (at < 0) at = area.text.indexOf(needle)
					if (at >= 0) area.select(at, at + needle.length)
				}
			}
		}
	}

	Component {
		id: grid
		Flow {
			x: 2
			y: 2
			width: window.width - 4
			spacing: 4
			Repeater {
				model: 64 * 40
				Rectangle {
					id: cell
					width: 16
					height: 16
					radius: 3
					color: ["#2563eb", "#dc2626", "#16a34a", "#d97706", "#9333ea", "#0891b2"][Math.floor(index / 3) % 6]
					// Each cell starts after its own delay (grid_delay_ms), then
					// fades between 1 and 0.2 every second, CSS ease-in-out,
					// alternating; animators run on the render thread.
					Timer { interval: ((index * 7) % 20) * 50; running: true; onTriggered: fade.start() }
					SequentialAnimation {
						id: fade
						loops: Animation.Infinite
						OpacityAnimator { target: cell; from: 1; to: 0.2; duration: 1000; easing.type: Easing.Bezier; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
						OpacityAnimator { target: cell; from: 0.2; to: 1; duration: 1000; easing.type: Easing.Bezier; easing.bezierCurve: [0.42, 0, 0.58, 1, 1, 1] }
					}
				}
			}
		}
	}
}
