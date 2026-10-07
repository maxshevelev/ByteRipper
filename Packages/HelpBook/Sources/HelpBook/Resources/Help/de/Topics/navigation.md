@source-sha 659724c265525225e4ed80a072672a46b87265743efab1d6372980c39d9a1f0d
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

Das Feld behält die zuletzt eingegebenen zehn Adressen. Darunter liegt die [[topic:bookmarks|Lesezeichenliste]]: Tab bringt die Tastatur dorthin, Return springt zum ausgewählten Lesezeichen.

Im Vergleichsmodus bewegt der Sprung **beide** Bereiche, die an dieselbe Adresse gebunden sind.

## Zurück, wo man war

Jeder Sprung merkt sich die Stelle, die er verlässt: „Gehe zu“, ein Lesezeichen, der nächste oder vorherige Unterschied, ein Suchtreffer, ein Klick in die Minimap, eine Zeile eines Werkzeugbereichs, für die der Dump zu Bytes außerhalb des Bildschirms rollt. **Darstellung ▸ Zurück** (**⌘[**) kehrt dorthin zurück — mit derselben Auswahl und denselben Zeilen auf dem Bildschirm —, **Darstellung ▸ Vorwärts** (**⌘]**) geht in die andere Richtung. Dieselben Befehle sind die Tasten **‹ ›** in der Symbolleiste, rechts vom Werkzeugmenü.

Bewegungen der Einfügemarke mit den Pfeiltasten, der Maus oder dem Rollbalken sind keine Sprünge und werden nicht gemerkt. Das Durchlaufen der Zeilen eines Werkzeugbereichs zählt als ein Sprung, gleich wie viele Zeilen es sind.

Der Verlauf gehört zum Tab und hält die letzten fünfzig Stellen. Im Vergleichsmodus umfasst eine Stelle beide Bereiche. Eine Stelle in einer Datei, die inzwischen geschlossen oder durch eine andere ersetzt wurde, wird übersprungen.

## Einen Block auswählen

**Bearbeiten ▸ Block auswählen…** wählt einen Bereich über Zahlen statt über die Maus: Anfang und Ende oder Anfang und Länge. Beide Felder nehmen Hexadezimalwerte mit dem Präfix `0x` und schlichtes Dezimal entgegen. Der Befehl dient der Auswahl von Hand, wenn Anfang, Ende oder Länge eines Bereichs bekannt oder errechnet sind.

! **Ende** ist die Adresse des letzten Bytes der Auswahl und nicht die des ersten Bytes dahinter. Ein Anfang `0x1000` mit einem Ende `0x1FFF` wählt daher genau `0x1000` Bytes aus.

## Den anderen Bereich mitführen

Die beiden Bereiche sind in Scrollposition, Einfügemarke und Auswahl miteinander gekoppelt. **Darstellung ▸ Bereiche tauschen** tauscht die Dateien zwischen den Bereichen.

Siehe auch: [[topic:minimap|Die Minimap]] — Bewegung mit dem Zeiger statt über Adressen.
