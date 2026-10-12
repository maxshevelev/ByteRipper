@source-sha aff3fae5028e99f37838a370d1a62e96d6b2d5afbd4a254cbca336d7db889b67
# Anmerkungen

> Kurze Vermerke zu Stellen in einer Datei, angelegt von Hand oder von einem verbundenen Agenten. Eine Anmerkung wird über den Bytes gezeigt und in einem eigenen Bereich aufgeführt.

Eine Anmerkung besteht aus einem Titel und einer Erläuterung zu einer Stelle in einer Datei: was die Bytes sind oder was dort gefunden wurde. Solange ihre Datei auf dem Bildschirm ist — in einem Tab oder in einem Teil, der die Adressen der Datei beibehält —, wird die Anmerkung über den Bytes mit einem gestrichelten Rahmen und einer leichten Tönung gezeigt. Verweilt der Zeiger auf diesen Bytes, erscheinen Titel und Erläuterung. Von Hand angelegte Anmerkungen sind grün, die des Agenten ([[topic:agent|Mit einem Agenten arbeiten]]) violett.

Eine Anmerkung gehört zur Datei, nicht zum Fenster. Sie bleibt erhalten, wenn die Datei geschlossen wird, und erscheint wieder, sobald die Datei geöffnet wird. Eine Anmerkung in einem nie gesicherten Dokument verschwindet mit diesem. Alle Anmerkungen bleiben erhalten, bis sie entfernt werden oder das Programm beendet wird.

## Eine Anmerkung anlegen

Die Bytes auswählen, innerhalb der Auswahl mit der rechten Maustaste klicken und **Anmerkung hinzufügen…** wählen. Einen Titel eingeben — einige Worte dazu, was die Bytes sind —, bei Bedarf darunter eine Erläuterung, und **Hinzufügen** klicken. In einem Fragment-Bereich angelegt, gehört die Anmerkung zu der Datei, aus der das Fragment stammt: zu denselben Bytes, wenn das Fragment die Adressen der Datei beibehält, sonst zu den Bytes des Fragments selbst; dort erscheint sie, wenn dieses Fragment wieder geöffnet wird.

## Der Bereich „Anmerkungen“

Solange es mindestens eine Anmerkung gibt, steht am Anfang des Docks am unteren Fensterrand jedes Tabs die Pille **Anmerkungen** ([[topic:fragments|Fragment-Bereiche]]). Ein Klick auf die Pille hebt den Bereich über den Dump. Ein zweiter Klick, das ⌄ in seinem Kopf, **Esc**, **⌘W** oder das Herunterziehen des Kopfes klappt ihn wieder in die Pille ein. Ein ✕ hat der Bereich nicht: Er verschwindet von selbst, sobald die letzte Anmerkung entfernt ist.

Legt der Agent eine Anmerkung an, während der Bereich eingeklappt ist oder gerade mit der ersten Anmerkung entsteht, zeigt die Pille eine runde rote Plakette mit der Zahl der noch nicht angesehenen Anmerkungen. Die Plakette verschwindet, sobald der Bereich angehoben wird; eine Anmerkung, die bei angehobenem Bereich entsteht, gilt als angesehen.

Der Bereich zeigt alle Anmerkungen in allen Dateien, geöffnet oder nicht, als Karten in so vielen Spalten, wie das Fenster breit ist. Eine Karte ist so gezeichnet wie die Anmerkung über dem Dump, in der Farbe ihres Urhebers; eine Karte des Agenten trägt vor dem Titel das Agentensymbol (einen Stecker), eine von Hand angelegte einen Stift. Ein Klick auf den Stift öffnet Titel und Erläuterung zum Bearbeiten; **Sichern** übernimmt die Änderung, die Stelle bleibt dieselbe. Eine Karte enthält:

- den Titel und ein ✕ auf der Ecke der Karte;
- den Dateinamen mit einem Punkt davor: gefüllt, solange die Datei geöffnet ist, hohl, solange sie es nicht ist;
- den Knoten der **UEFI-Struktur**, in dem die Stelle liegt, mit seinem übergeordneten Knoten, so wie die Ergebnisse der Inhaltssuche ihn benennen — als Link, der die Stelle zeigt. Vor dem Knoten trägt eine Stelle in entpackten oder dekodierten Bytes Plaketten mit den Codecs, die die Bytes durchlaufen haben (`LZMA`, `XOR C0`), wie im Kopf eines Fragment-Bereichs. Ein Knotenname, der nicht in die Zeile passt, wird in der nächsten Zeile unter seinem eigenen Anfang fortgesetzt. In einer Datei ohne Firmware-Baum stehen dort stattdessen die Adressen;
- die ganze Erläuterung;
- die zugehörigen Anmerkungen — etwa ein Zeiger und sein Ziel oder eine Prüfsumme und die Daten, über die sie gebildet wird —, jede als Link auf ihre Karte. Über dem Dump folgen sie auf die Erläuterung, nach **Zugehörige Anmerkungen:**.

Ein Klick wählt eine Karte aus, mit **⌘** oder **⇧** mehrere; die Pfeiltasten bewegen die Auswahl. Ein Doppelklick auf eine Karte oder **Return** holt die Datei nach vorn oder öffnet sie in einem neuen Tab und wählt die Stelle aus; dieser Sprung wird im Verlauf festgehalten ([[topic:navigation|Sich bewegen]]). Ein Bereich, der den Dump verdeckt, wird dabei eingeklappt. In einem Firmware-Image öffnet sich neben dem Dump die **UEFI-Struktur** an dem Knoten, in dem die Stelle liegt, wie bei einem Klick auf ein Ergebnis der Inhaltssuche. Eine Stelle in entpackten oder dekodierten Bytes öffnet sich in einem Fragment-Bereich mit diesen Bytes: Dort ist sie ausgewählt, und die **UEFI-Struktur** dieses Bereichs ist bis zu dem Knoten aufgeklappt, in dem sie liegt. Wurde die Datei inzwischen verschoben oder gelöscht, meldet das Programm dies.

Das ✕ auf einer Karte entfernt diese Anmerkung, **Entf** die ausgewählten Karten. Verweise auf eine entfernte Anmerkung verschwinden mit ihr.
