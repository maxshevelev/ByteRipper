@source-sha 304bb3ae2b757249f4048345b23ef60b41fdee06a420f389779a1095610670eb
# Sichern

> Roter Text heißt, die Änderung gibt es nur hier. Sichern Sie, und sie steht in der Datei.

- **⌘S — Sichern.** Schreibt das Dokument des Bereichs zurück in seine Datei. Ein unbenanntes Dokument öffnet stattdessen ein Sicherungsfenster.
- **⇧⌘S — Sichern unter…** Schreibt es an einen neuen Ort, und der Bereich folgt der neuen Datei.
- **Ablage ▸ Auf gesicherten Stand zurücksetzen** wirft Ihre Änderungen weg und liest die Datei neu vom Volume.
- **Ablage ▸ In der Quelle aktualisieren** ist das dritte Ziel: für einen [[topic:fragments|Fragment-Bereich]] schreibt es das Fragment zurück in das Image, aus dem es stammt, statt in eine Datei.

## Was ungesichert ist

Bytes, die Sie geändert haben, erscheinen **rot**, bis sie gesichert sind, und der Bereichskopf sagt, dass das Dokument geändert ist. Dieses Paar prüft man, bevor man eine Datei an einen Programmer gibt: kein Rot mehr, und der Kopf sauber.

## Wenn sich die Datei unter Ihnen ändert

ByteRipper beobachtet die geöffnete Datei. Schreibt etwas anderes sie neu — etwa Ihre Programmer-Software, die den Chip in denselben Pfad ausliest — merkt das Programm es und sagt es, statt später still über den neuen Inhalt zu sichern.

## Dokumente ohne Datei

Manche Dokumente sind mit Absicht unbenannt und haben keinen Pfad, weshalb ⌘S fragt, wohin damit:

- **Ablage ▸ Neue Datei** (⌘N).
- Das Ergebnis eines [[topic:join-duplicate|Zusammenfügens]]: zwei Dumps zu verbinden ergibt ein *neues* Image, und ein versehentliches ⌘S darf es nicht über eine der Hälften schreiben.
- Das Ergebnis von **Duplizieren**.
- Ein Fragment, das aus einem Image geholt wurde.

! Bewahren Sie den ursprünglichen Dump. Sichern Sie Ihre geänderte Fassung unter neuem Namen — `board_patched.bin` neben `board_original.bin`. Ein überschriebener Dump ist ein Chip, den Sie erneut lesen müssen, und nach einem Spannungsfehler gelingt das womöglich kein zweites Mal.
