@source-sha e69ea43cc62575909ba9d4f66e2f3fc61bc2d6aeeb9d99b86d39727efc20f209
# Fragment-Bereiche: ein Stück eines Dumps als eigene Datei

> Ein Fragment aus einem Image holen, als eigene Datei bearbeiten und zurückschreiben.

Wenn ein [[topic:tools-overview|Firmware-Panel]] Ihnen ein Fragment des Images gibt — eine Region, ein Volume, ein Modul, den entpackten Rumpf einer Sektion — öffnet es sich als **Fragment-Bereich**: ein Bereich, der von unten über den Dump fährt, aus dem er stammt.

Die Quelle bleibt darüber sichtbar. Eingeklappt wird das Fragment zu einer Pille im Dock am unteren Fensterrand, sodass die Pillen dort die Fragmente sind, die Sie aus *diesem* Image geholt haben.

## Was sich mit einem Fragment machen lässt

- Es lesen und darin suchen wie in einer gewöhnlichen Datei, mit eigenen Adressen ab null — viel einfacher, als Offsets in der Quelle nachzuzählen.
- Es bearbeiten.
- **Ablage ▸ In der Quelle aktualisieren** schreibt die geänderten Bytes zurück in den Bereich, aus dem sie kamen, als einen einzigen Widerrufsschritt im Quelldokument. Klappen Sie den Bereich ein, und die Änderung steht schon da, im Dump dahinter.
- Es als eigene Datei sichern, wenn Sie das herausgelöste Fragment brauchen und nicht die geänderte Quelle.

## Wenn das Zurückschreiben abgelehnt wird

Die Aktualisierung prüft, bevor sie schreibt, und sagt, warum sie es nicht tut:

- **Die Quelle ist geschlossen**, oder jener Bereich hält jetzt eine andere Datei. Die Verbindung führt zum geöffneten Dokument, nicht zu einem Pfad auf dem Volume, und wird nie festgeschrieben.
- **Die Quelle ist schreibgeschützt.**
- **Die Länge hat sich geändert.** Ein schlicht kopiertes Fragment geht nur in seiner eigenen Länge zurück: die Bytes dahinter gehören nicht ihm. Hat Ihre Änderung die Größe verändert, ändern Sie nicht mehr ein Fragment — Sie bauen das Image um es herum neu.
- **Die Quelle hat sich unter Ihnen geändert**, seit das Fragment geöffnet wurde. Das ist keine Ablehnung, sondern eine Rückfrage: es fragt, bevor es überschreibt.

## Entpackte Fragmente

Eine komprimierte UEFI-Sektion lässt sich **entpackt** öffnen. Sie sehen dann nicht die Bytes der Datei, sondern das, wozu sie sich entfalten. Geändert und zurückgeschrieben, wird das Ganze neu komprimiert und das Image um die neue Größe herum neu gelegt. Rechnen Sie damit, dass das Ergebnis nicht Byte für Byte dem Original des Herstellers gleicht, selbst wenn Sie nichts ändern: ein anderer Kompressor macht aus derselben Eingabe eine andere Ausgabe.

Siehe auch: [[topic:saving|Sichern]], [[topic:bench-safety|Regeln am Arbeitsplatz]].
