@source-sha 316bfd9b1d66d6bb5211dd78df12a91bc89ea5574659a09d575b250b8e8bfb9c
# Bytes bearbeiten

> Tippen überschreibt die vorhandenen Bytes. Jeder Vorgang, der die Länge der Datei ändert, fragt vorher nach.

Hex-Ziffern werden in der Hex-Spalte eingegeben, Zeichen in der Textspalte. Beides ändert dieselben Bytes.

In der Hex-Spalte ersetzt die erste eingegebene Ziffer das obere Halbbyte und die zweite das untere, danach rückt die Einfügemarke weiter. In der Textspalte schreibt ein druckbares Zeichen sein Byte; alles außerhalb von ASCII wird übergangen.

## Überschreiben ist die Vorgabe

Tippen **überschreibt**, und Einsetzen mit ⌘V überschreibt. Kein Byte wird verschoben, und jede Adresse in der Datei bezeichnet weiterhin das, was sie vorher bezeichnete.

Das folgt aus dem Aufbau eines Firmware-Images, in dem eine Adresse eine Position auf dem Baustein ist: Eine Tabelle zeigt auf `0x800000`, eine Signatur deckt einen festen Bereich ab, eine Regionsgrenze steht im Descriptor. Ein einziges vorn eingefügtes Byte macht alle diese Angaben falsch.

- **Entf und Rückschritt kürzen die Datei nicht.** Sie füllen mit `0x00`: Entf das Byte an der Einfügemarke, Rückschritt das davor. Eine Auswahl wird durchgehend mit `0x00` gefüllt.
- **Bearbeiten ▸ Auswahl füllen mit…** füllt die Auswahl mit einem gewählten Byte. Im Flash-Speicher ist das meist `FF`, der Wert gelöschter Zellen.

## Vorgänge, die die Länge doch ändern

Drei Vorgänge ändern sie doch, und jeder fragt vor der Ausführung nach:

- **Bearbeiten ▸ Einsetzen mit Verschieben…** — einsetzen und alles dahinter verschieben.
- **Bearbeiten ▸ Bytes löschen…** — wirklich löschen und alles dahinter verschieben.
- **Bearbeiten ▸ Einfügemodus** (⌥⌘I) — ein Tippmodus, in dem Tasten einfügen und löschen statt zu überschreiben. Er fragt einmal je Datei statt bei jedem Anschlag, sagt es in der Statuszeile und ändert die Form der Einfügemarke.

Die Rückfragen lassen sich in den [[topic:settings|Einstellungen ▸ Bearbeiten]] abschalten oder über das Kästchen „Nicht mehr fragen“ im Dialog selbst. Sie sind voreingestellt, weil diese Vorgänge jede Adresse hinter der Stelle ändern, an der sie wirken.

! Die Länge eines SPI-Dumps darf sich nicht ändern, da die Kapazität des Bausteins fest ist. Siehe [[topic:bench-safety|Einschränkungen beim Bearbeiten eines Images]].

## Widerrufen

Jede Änderung ist ein Widerrufsschritt (⌘Z), auch die großen: ein Zusammenfügen, ein Füllen, ein von einem [[topic:tools-overview|Werkzeug]] geschriebener Vorgang, ein in die Quelle zurückgeschriebenes Fragment. Widerrufen wird je Dokument geführt.
