@source-sha 80ee158714d76f00a3ef24c9c28c9a74361bd2689f9df227cab68e417307fdfb
# Anmerkungen

> Kurze Vermerke zu Stellen in einer Datei, angelegt von Hand oder von einem verbundenen Agenten. Eine Anmerkung wird über den Bytes gezeigt und in einem eigenen Fenster aufgeführt.

Eine Anmerkung besteht aus einem Titel und einer Erläuterung zu einer Stelle in einer Datei: was die Bytes sind oder was dort gefunden wurde. Solange ihre Datei auf dem Bildschirm ist — in einem Tab oder in einem Teil, der die Adressen der Datei beibehält —, wird die Anmerkung über den Bytes mit einem gestrichelten Rahmen und einer leichten Tönung gezeigt. Verweilt der Zeiger auf diesen Bytes, erscheinen Titel und Erläuterung. Von Hand angelegte Anmerkungen sind grün, die des Agenten ([[topic:agent|Mit einem Agenten arbeiten]]) violett.

Eine Anmerkung gehört zur Datei, nicht zum Fenster. Sie bleibt erhalten, wenn die Datei geschlossen wird, und erscheint wieder, sobald die Datei geöffnet wird. Eine Anmerkung in einem nie gesicherten Dokument verschwindet mit diesem. Alle übrigen Anmerkungen bleiben erhalten, bis sie entfernt werden, auch über einen Neustart des Programms hinweg; gespeichert werden sie nur auf diesem Mac.

## Eine Anmerkung anlegen

Die Bytes auswählen, innerhalb der Auswahl mit der rechten Maustaste klicken und **Anmerkung hinzufügen…** wählen. Einen Titel eingeben — einige Worte dazu, was die Bytes sind —, bei Bedarf darunter eine Erläuterung, und **Hinzufügen** klicken. In einem Fragment-Bereich angelegt, gehört die Anmerkung zu der Datei, aus der das Fragment stammt: zu denselben Bytes, wenn das Fragment die Adressen der Datei beibehält, sonst zu den Bytes des Fragments selbst; dort erscheint sie, wenn dieses Fragment wieder geöffnet wird.

Ein Knoten der **UEFI-Struktur** wird ebenso annotiert: mit der rechten Maustaste auf seine Zeile klicken und **Anmerkung hinzufügen…** wählen; als Titel ist der Name des Knotens vorgegeben. Die Anmerkung gilt dem Knoten selbst, nicht nur seinen Bytes: Bei einem Knoten in einem komprimierten Abschnitt oder einem Eintrag eines kodiert gespeicherten Lenovo-LENV-Blocks wird die Stelle in den entpackten bzw. dekodierten Bytes festgehalten, und die Karte zeigt die Codecs als Plaketten.

## Das Fenster „Anmerkungen“

Die Anmerkungen gehören zu ByteRipper, nicht zu einem Fenster, und stehen deshalb an einer Stelle: im Fenster **Anmerkungen**. **Fenster ▸ Anmerkungen** oder die Taste **Anmerkungen** in der Symbolleiste gleich nach **Segmente** öffnet es als Tab neben den Tabs der Dumps oder holt es nach vorn, wenn es schon offen ist. Es gibt nur ein solches Fenster. Es kann auch ohne Anmerkungen offen sein und erklärt dann, wie eine angelegt wird. Geschlossen wird es wie jeder Tab, mit **⌘W** oder dem ✕ auf dem Tab, und ebenso wieder geöffnet. Solange es geschlossen ist, bleiben die Anmerkungen erhalten.

Legt der Agent eine Anmerkung an, während das Fenster geschlossen ist oder ein anderer Tab vorn liegt, zeigt die Taste **Anmerkungen** in der Symbolleiste eine runde Plakette in Violett, der Farbe der Anmerkungen des Agenten, mit der Zahl der noch nicht angesehenen Anmerkungen. Die Plakette verschwindet, sobald das Fenster nach vorn geholt wird; eine Anmerkung, die entsteht, während es vorn liegt, gilt als angesehen.

Das Fenster zeigt alle Anmerkungen in allen Dateien, geöffnet oder nicht, als Karten in so vielen Spalten, wie das Fenster breit ist. Eine Karte ist so gezeichnet wie die Anmerkung über dem Dump, in der Farbe ihres Urhebers; eine Karte des Agenten trägt vor dem Titel das Agentensymbol (einen Stecker), eine von Hand angelegte einen Stift. Ein Klick auf den Stift öffnet Titel und Erläuterung zum Bearbeiten; **Sichern** übernimmt die Änderung, die Stelle bleibt dieselbe. Eine Karte enthält:

- den Titel und ein ✕ auf der Ecke der Karte;
- den Dateinamen mit einem Punkt davor: gefüllt, solange die Datei geöffnet ist, hohl, solange sie es nicht ist;
- den Knoten der **UEFI-Struktur**, in dem die Stelle liegt, mit seinem übergeordneten Knoten, so wie die Ergebnisse der Inhaltssuche ihn benennen — als Link, der die Stelle zeigt. Vor dem Knoten trägt eine Stelle in entpackten oder dekodierten Bytes Plaketten mit den Codecs, die die Bytes durchlaufen haben (`LZMA`, `XOR C0`), wie im Kopf eines Fragment-Bereichs. Ein Knotenname, der nicht in die Zeile passt, wird in der nächsten Zeile unter seinem eigenen Anfang fortgesetzt. In einer Datei ohne Firmware-Baum stehen dort stattdessen die Adressen;
- die ganze Erläuterung;
- die zugehörigen Anmerkungen — etwa ein Zeiger und sein Ziel oder eine Prüfsumme und die Daten, über die sie gebildet wird —, jede als Link auf ihre Karte. Über dem Dump folgen sie auf die Erläuterung, nach **Zugehörige Anmerkungen:**.

Die Karte der zuletzt angelegten Anmerkung steht an erster Stelle. Eine Karte, die angelegt wurde, seit das Fenster zuletzt sichtbar war, trägt am oberen Rand die Marke **Neu**; die Marke verschwindet, sobald das Fenster das nächste Mal angezeigt wird.

Eine Karte lässt sich mit der Maus an eine andere Stelle ziehen. Während sie bewegt wird, weichen die übrigen Karten aus und geben ihr Platz frei; nach dem Loslassen reihen sich die Karten lückenlos aneinander. Die gewählte Reihenfolge bleibt erhalten, und die Karte einer neuen Anmerkung erscheint weiterhin an erster Stelle.

Ein Klick wählt eine Karte aus, mit **⌘** oder **⇧** mehrere; die Pfeiltasten bewegen die Auswahl. Ein Doppelklick auf eine Karte oder **Return** holt die Datei nach vorn oder öffnet sie in einem neuen Tab und wählt die Stelle aus; dieser Sprung wird im Verlauf festgehalten ([[topic:navigation|Sich bewegen]]). In einem Firmware-Image öffnet sich neben dem Dump die **UEFI-Struktur** an dem Knoten, in dem die Stelle liegt, wie bei einem Klick auf ein Ergebnis der Inhaltssuche. Eine Stelle in entpackten oder dekodierten Bytes öffnet sich in einem Fragment-Bereich mit diesen Bytes: Dort ist sie ausgewählt, und die **UEFI-Struktur** dieses Bereichs ist bis zu dem Knoten aufgeklappt, in dem sie liegt. Muss die Datei dafür erst geöffnet werden, wird zunächst ihre Struktur gelesen, und die Abschnitte auf dem Weg zur Stelle werden entpackt — bei einem großen Image einige Sekunden; währenddessen zeigt ein Blatt über dem Fenster den Fortschritt. **Abbrechen** lässt die Datei geöffnet, springt aber nicht zur Stelle. Wurde die Datei inzwischen verschoben oder gelöscht, meldet das Programm dies.

Das ✕ auf einer Karte entfernt diese Anmerkung, **Entf** die ausgewählten Karten. Verweise auf eine entfernte Anmerkung verschwinden mit ihr.
