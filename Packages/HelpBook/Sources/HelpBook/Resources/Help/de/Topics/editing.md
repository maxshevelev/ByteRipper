@source-sha a3460ac0ff8d3770d5ce52b1b3f91b4b4bc4a349ad9e4dab3c68751da5377c5f
# Bytes bearbeiten

> Tippen überschreibt die vorhandenen Bytes. Jeder Vorgang, der die Länge der Datei ändert, fragt vorher nach.

Hex-Ziffern werden in der Hex-Spalte eingegeben, Zeichen in der Textspalte. Beides ändert dieselben Bytes.

In der Hex-Spalte ersetzt die erste eingegebene Ziffer das obere Halbbyte und die zweite das untere, danach rückt die Einfügemarke weiter. In der Textspalte schreibt ein druckbares Zeichen sein Byte; alles außerhalb von ASCII wird übergangen.

## Überschreiben ist die Vorgabe

Tippen **überschreibt**, und Einsetzen mit ⌘V überschreibt. Kein Byte wird verschoben, und jede Adresse in der Datei bezeichnet weiterhin das, was sie vorher bezeichnete.

Das folgt aus dem Aufbau eines Firmware-Images, in dem eine Adresse eine Position auf dem Baustein ist: Eine Tabelle zeigt auf `0x800000`, eine Signatur deckt einen festen Bereich ab, eine Regionsgrenze steht im Descriptor. Ein einziges vorn eingefügtes Byte macht alle diese Angaben falsch.

- **Entf und Rückschritt kürzen die Datei nicht.** Sie füllen mit `0x00`: Entf das Byte an der Einfügemarke, Rückschritt das davor. Eine Auswahl wird durchgehend mit `0x00` gefüllt.
- **Bearbeiten ▸ Auswahl füllen mit…** füllt die Auswahl mit einem gewählten Byte. Im Flash-Speicher ist das meist `FF`, der Wert gelöschter Zellen.

## In den anderen Bereich kopieren

**Bearbeiten ▸ In den anderen Bereich kopieren** (⌥⌘C) schreibt die Auswahl des aktiven Bereichs in den anderen Bereich, über dieselben Adressen. Das ist Kopieren und Einsetzen in einem Schritt — ohne Zwischenablage und ohne den Bereich ein zweites Mal auszuwählen. Der Befehl braucht zwei geöffnete Dateien und eine Auswahl. Derselbe Befehl steht im Kontextmenü über einer Auswahl; dort kopiert er aus dem Bereich, auf den geklickt wurde, ob dieser aktiv ist oder nicht.

Die Kopie überschreibt wie ⌘V und ist ein Widerrufsschritt in der Datei, in die sie geschrieben wurde. Danach ist der Bereich in dieser Datei ausgewählt. Widerrufen wird der Schritt dort: Der Bereich wird aktiv gemacht, dann ⌘Z.

Der Befehl lehnt ab und schreibt nichts, wenn die andere Datei schreibgeschützt geöffnet ist oder die Auswahl über das Ende der anderen Datei hinausreicht. Die andere Datei wird dadurch nicht länger.

## Vorgänge, die die Länge doch ändern

Drei Vorgänge ändern sie doch, und jeder fragt vor der Ausführung nach:

- **Bearbeiten ▸ Einsetzen mit Verschieben…** — einsetzen und alles dahinter verschieben.
- **Bearbeiten ▸ Bytes löschen…** — wirklich löschen und alles dahinter verschieben.
- **Bearbeiten ▸ Einfügemodus** (⌥⌘I) — ein Tippmodus, in dem Tasten einfügen und löschen statt zu überschreiben. Er fragt einmal je Datei statt bei jedem Anschlag, sagt es in der Statuszeile und ändert die Form der Einfügemarke. Ein Klick auf die Anzeige **OVR** / **INS** in der Statuszeile schaltet denselben Modus um ([[topic:hex-view|Die Hex-Ansicht lesen]]).

Die Rückfragen lassen sich in den [[topic:settings|Einstellungen ▸ Allgemein]] abschalten oder über das Kästchen „Nicht mehr fragen“ im Dialog selbst. Sie sind voreingestellt, weil diese Vorgänge jede Adresse hinter der Stelle ändern, an der sie wirken.

! Die Länge eines SPI-Dumps darf sich nicht ändern, da die Kapazität des Bausteins fest ist. Siehe [[topic:bench-safety|Einschränkungen beim Bearbeiten eines Images]].

## Widerrufen

Jede Änderung ist ein Widerrufsschritt (⌘Z), auch die großen: ein Zusammenfügen, ein Füllen, ein von einem [[topic:tools-overview|Werkzeug]] geschriebener Vorgang, ein in die Quelle zurückgeschriebenes Fragment. Widerrufen wird je Dokument geführt.

Wie weit sich zurück widerrufen lässt, legen zwei Grenzen in den [[topic:settings|Einstellungen ▸ Allgemein]] fest, jede für jedes Dokument für sich. **Größe des Widerrufsverlaufs:** zählt die Bytes der Änderungen, den vorherigen wie den neuen Inhalt: Das Überschreiben von 1 GB belegt 2 GB. Ein Füllen bewahrt nur den ersetzten Inhalt auf: Statt des Geschriebenen wird nur die wiederholte Byte-Folge aufbewahrt. **Widerrufsschritte:** zählt die Änderungen; ein eingegebenes Byte ist eine. Jenseits einer der beiden Grenzen lassen sich die ältesten Änderungen nicht mehr widerrufen, und das Dokument bleibt geändert. Eine niedrigere Grenze gilt ab der nächsten Änderung. Eine einzelne Änderung, die größer ist als die Größengrenze, bleibt dennoch erhalten und kann widerrufen werden.

Die Bytes der Änderungen werden in einer Datei auf dem Datenträger aufbewahrt, nicht im Arbeitsspeicher; ein großes Ersetzen belegt so nicht seine Größe im Arbeitsspeicher, solange es widerrufen werden kann. Solange der [[topic:workspace|Arbeitsbereich]] oder ein [[topic:projects|Projekt]] aufbewahrt wird, liegt diese Datei daneben und dient zugleich als dessen Verlauf, sodass die Bytes einer Änderung nur einmal auf den Datenträger geschrieben werden. Andernfalls ist es eine temporäre Datei, die beim Schließen des Dokuments entfernt wird.

## In einem Eingabefeld

Solange ein Eingabefeld den Fokus hat — die Suchleiste, ein Formular, ein Dialog —, wirken die Bearbeitungstasten auf dessen Text, wie überall in macOS: ⌘A wählt den Text des Feldes aus, ⌘C, ⌘X und ⌘V kopieren, schneiden aus und fügen Text ein, ⌘Z widerruft die Eingabe. Auf die Bytes wirken sie nur, solange der Dump den Fokus hat.

**Bearbeiten ▸ Ausschneiden** (⌘X) funktioniert nur in einem Eingabefeld. Bytes werden nicht ausgeschnitten, da dies die Datei verkürzen würde; solange der Dump den Fokus hat, ist der Menüpunkt nicht verfügbar.
