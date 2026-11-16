@source-sha ef39ea28dcd6acfc5cc80e433f77e21a068752d4d045da60a6db77a07beeac2f
# Sich bewegen

> Zwischen Unterschieden springen, zu einer Adresse springen oder auf einem Byte stehen und ablesen, wo man ist.

## Zwischen Unterschieden

- **⌥⌘→** — nächster Unterschied, **⌥⌘←** — vorheriger.
- **⇧⌥⌘→ / ⇧⌥⌘←** — nächster / vorheriger **gleicher** Block: der Anfang der nächsten Strecke, auf der die Dateien übereinstimmen. Nützlich, wenn sich fast das ganze Image unterscheidet und man die Inseln sucht, die passen.

Ein „Unterschied“ ist beim Springen eine ganze Folge abweichender Bytes, nicht jedes einzelne: ein abweichender 4-KB-Block ist eine Station, nicht viertausend.

## Zu einer Adresse

**⌘L** öffnet „Gehe zu“. Geben Sie eine Adresse ein und drücken Sie Return:

- `0x1FE00` — hexadezimal, mit dem Präfix `0x` (es steht schon im Feld).
- `130560` — dezimal, ohne Präfix.

Das Feld behält die letzten zehn Einträge, Summen eingeschlossen (siehe unten). Darunter liegt die [[topic:bookmarks|Lesezeichenliste]]: Tab bringt die Tastatur dorthin, Return springt zum ausgewählten Lesezeichen.

Im Vergleichsmodus bewegt der Sprung **beide** Bereiche, die an dieselbe Adresse gebunden sind.

## Eine Summe statt einer Zahl

Jedes Feld, das eine Adresse oder eine Länge erwartet, nimmt auch eine Summe an: Zahlen, verbunden durch `+` und `-`, in beliebiger Basis. Das gilt für „Gehe zu“, für **Bearbeiten ▸ Block auswählen…** und **Bearbeiten ▸ Schnitt hinzufügen…** sowie für die Adresse eines Lesezeichens.

- `0x1FE000 + 4096` — eine Adresse hexadezimal plus eine Länge dezimal.
- `0x2C0000 - 0x400 - 16` — beliebig viele Glieder, von links nach rechts gerechnet.

Die Summe bleibt so im Feld stehen, wie sie eingegeben wurde. Ihr Ergebnis steht am rechten Rand des Feldes in kräftigerer Schrift, und der Befehl wird auf dieses Ergebnis angewendet. „Gehe zu“ und „Block auswählen“ wiederholen die Summe zusätzlich unter dem Feld, jedes Glied hexadezimal und das Ergebnis in beiden Basen: `0x1FE000 + 0x1000 = 0x1FF000 (2093056)`.

! Ein Glied ohne das Präfix `0x`, das nur aus Dezimalziffern besteht, ist dezimal: `0x1FE000 + 40` addiert vierzig, nicht `0x40`. Die Zeile unter dem Feld zeigt, wie jedes Glied gelesen wurde. Aus demselben Grund zeigt eine einzelne Zahl, die ohne Präfix eingegeben wurde, am rechten Rand ihren Hexadezimalwert.

Klammern und Multiplikation werden nicht unterstützt. Eine Summe mit negativem Ergebnis oder mit einem Ergebnis, das nicht in 64 Bit passt, wird abgewiesen.

Die Pfeiltaste am rechten Rand des Feldes oder **↓** öffnet die Liste der letzten zehn Einträge. Die Liste gilt für alle diese Felder gemeinsam: Sie enthält die Adressen, zu denen „Gehe zu“ gesprungen ist, und jede Summe, mit der ein Befehl ausgeführt wurde, jeweils mit ihrem Ergebnis. Ein gewählter Eintrag wird in das Feld übernommen, wo er geprüft und korrigiert werden kann; bis zur Bestätigung des Befehls geschieht nichts.

## Zurück, wo man war

Jeder Sprung merkt sich die Stelle, die er verlässt: „Gehe zu“, ein Lesezeichen, der nächste oder vorherige Unterschied, ein Suchtreffer, ein Klick in die Minimap, ein Klick auf eine Zeile eines Werkzeugbereichs. **Darstellung ▸ Zurück** (**⌘[**) kehrt dorthin zurück — mit derselben Auswahl, denselben Zeilen auf dem Bildschirm und derselben im Werkzeugbereich gewählten Zeile samt ihren Zonen —, **Darstellung ▸ Vorwärts** (**⌘]**) geht in die andere Richtung. Dieselben Befehle sind die Tasten **‹ ›** in der Symbolleiste, rechts vom Werkzeugmenü.

Scrollen, Bild auf/ab sowie Pos1/Ende werden gemerkt, sobald die Einfügemarke dadurch vom Bildschirm verschwindet: „Zurück“ kehrt zur Einfügemarke und zu den Zeilen zurück, die mit ihr sichtbar waren. Weiteres Scrollen, solange die Einfügemarke nicht sichtbar ist, ist derselbe Schritt. Bewegungen der Einfügemarke mit den Pfeiltasten oder der Maus sind keine Sprünge und werden nicht gemerkt. Auch das Durchlaufen der Zeilen eines Werkzeugbereichs mit den Pfeiltasten wird nicht gemerkt — nur ein Klick auf eine Zeile. Führen „Zurück“ oder „Vorwärts“ zu einem Schritt, der mit einem Klick in der Tabelle eines Werkzeugbereichs gemacht wurde, geht die Tastatur in diese Tabelle, und die Pfeiltasten setzen bei der zurückgeholten Zeile an.

Der Verlauf gehört zum Tab und hält die letzten fünfzig Stellen. Im Vergleichsmodus umfasst eine Stelle beide Bereiche. Ist der Werkzeugbereich geschlossen, bringen „Zurück“ und „Vorwärts“ nur den Dump zurück; ist dasselbe Werkzeug wieder offen, werden auch seine Zeilen wieder gewählt. Eine Stelle in einer Datei, die inzwischen geschlossen oder durch eine andere ersetzt wurde, wird übersprungen.

## Einen Block auswählen

**Bearbeiten ▸ Block auswählen…** wählt einen Bereich über Zahlen statt über die Maus: Anfang und Ende oder Anfang und Länge. Beide Felder nehmen Hexadezimalwerte mit dem Präfix `0x` und schlichtes Dezimal entgegen. Der Befehl dient der Auswahl von Hand, wenn Anfang, Ende oder Länge eines Bereichs bekannt oder errechnet sind.

! **Ende** ist die Adresse des letzten Bytes der Auswahl und nicht die des ersten Bytes dahinter. Ein Anfang `0x1000` mit einem Ende `0x1FFF` wählt daher genau `0x1000` Bytes aus.

## Den anderen Bereich mitführen

Die beiden Bereiche sind in Scrollposition, Einfügemarke und Auswahl miteinander gekoppelt. **Darstellung ▸ Bereiche tauschen** tauscht die Dateien zwischen den Bereichen.

Siehe auch: [[topic:minimap|Die Minimap]] — Bewegung mit dem Zeiger statt über Adressen.
