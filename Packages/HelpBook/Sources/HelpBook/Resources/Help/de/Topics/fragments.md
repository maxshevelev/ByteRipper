@source-sha 1c9f31aeb56039daab40e1a18491e151581715677509004c941470f302cee8de
# Fragment-Bereiche: ein Stück eines Dumps als eigene Datei

> Einen Teil eines Images entnehmen, als eigene Datei bearbeiten und zurückschreiben.

Ein Teil eines Images, den ein [[topic:tools-overview|Werkzeug]] bereitstellt — eine Region, ein Volume, ein Modul, der entpackte Rumpf einer Sektion —, öffnet sich als **Fragment-Bereich**: ein Bereich, der von unten über den Dump fährt, aus dem der Teil stammt.

Die Quelle bleibt darüber sichtbar. Eingeklappt wird das Fragment zu einer Pille im Dock am unteren Fensterrand; die Pillen dort entsprechen den Teilen, die aus *diesem* Image entnommen wurden.

## Was ein Fragment unterstützt

- Lesen und Suchen wie in einer gewöhnlichen Datei, mit eigenen Adressen ab null statt mit den Adressen, die der Teil in der Quelle einnimmt.
- Bearbeiten.
- **Ablage ▸ In der Quelle aktualisieren** schreibt die geänderten Bytes zurück in den Bereich, aus dem sie stammen, als einen einzigen Widerrufsschritt im Quelldokument.
- Sichern als eigene Datei auf dem Volume, wenn der entnommene Teil gebraucht wird und nicht die geänderte Quelle.

## Wenn das Zurückschreiben abgelehnt wird

Vor dem Schreiben werden die folgenden Bedingungen geprüft, und das Programm nennt die, an der es scheitert:

- **Die Quelle ist geschlossen**, oder jener Bereich hält jetzt eine andere Datei. Die Verbindung führt zum geöffneten Dokument und nicht zu einem Pfad auf dem Volume, und sie wird nirgends festgehalten.
- **Die Quelle ist schreibgeschützt.**
- **Die Länge hat sich geändert.** Ein kopierter Teil wird genau in seiner eigenen Länge zurückgeschrieben; die Bytes dahinter zu verschieben steht dem Fragment nicht zu. Eine Änderung, welche die Länge verändert hat, wird deshalb abgelehnt.
- **Die Quelle hat sich geändert**, nachdem das Fragment geöffnet wurde. Das ist keine Ablehnung, sondern eine Rückfrage: Das Programm fragt, bevor es überschreibt.

## Entpackte Fragmente

Eine komprimierte UEFI-Sektion lässt sich **entpackt** öffnen. Angezeigt werden dann nicht die in der Datei gehaltenen Bytes, sondern das, wozu sie sich entfalten. Nach dem Bearbeiten und Zurückschreiben wird die Sektion neu komprimiert und das Image um die entstandene Größe herum neu gelegt. Das Ergebnis gleicht dem Original des Herstellers auch dann nicht Byte für Byte, wenn nichts geändert wurde, da ein anderer Kompressor aus derselben Eingabe eine andere Ausgabe erzeugt.

Siehe auch: [[topic:saving|Sichern]], [[topic:bench-safety|Einschränkungen beim Bearbeiten eines Images]].
