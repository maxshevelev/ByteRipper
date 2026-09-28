@source-sha e3d74f4854a896eb517f8c6a41556308ddafebb2834260c066dc75ed51b0bdef
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

## Einen Block auswählen

**Bearbeiten ▸ Block auswählen…** wählt einen Bereich über Zahlen statt über die Maus: Anfang und Ende oder Anfang und Länge. Beide Felder nehmen Hexadezimalwerte mit dem Präfix `0x` und schlichtes Dezimal entgegen. Der Befehl dient der Auswahl von Hand, wenn Anfang, Ende oder Länge eines Bereichs bekannt oder errechnet sind.

! **Ende** ist die Adresse des letzten Bytes der Auswahl und nicht die des ersten Bytes dahinter. Ein Anfang `0x1000` mit einem Ende `0x1FFF` wählt daher genau `0x1000` Bytes aus.

## Den anderen Bereich mitführen

Die beiden Bereiche sind in Scrollposition, Einfügemarke und Auswahl miteinander gekoppelt. **Darstellung ▸ Bereiche tauschen** tauscht die Dateien zwischen den Bereichen.

Siehe auch: [[topic:minimap|Die Minimap]] — Bewegung mit dem Zeiger statt über Adressen.
