@source-sha 27e01a3af57e9fb43c57156d4336ec597c3b3941f4d1527752d62c90f74ca446
# Sichern

> Rot kennzeichnet ein Byte, das von der Datei auf dem Volume abweicht. Das Sichern schreibt diese Bytes in die Datei, und das Rot wird aufgehoben.

- **⌘S — Sichern.** Schreibt das Dokument des Bereichs zurück in seine Datei. Ein unbenanntes Dokument öffnet stattdessen ein Sicherungsfenster, damit ein Name gewählt werden kann.
- **⇧⌘S — Sichern unter…** Schreibt es an einen neuen Ort, und der Bereich folgt der neuen Datei.
- **Ablage ▸ Auf gesicherten Stand zurücksetzen** verwirft die Änderungen und liest die Datei neu vom Volume.
- **Ablage ▸ In der Quelle aktualisieren** ist das dritte Ziel: für einen [[topic:fragments|Fragment-Bereich]] schreibt es das Fragment zurück in das Image, aus dem es stammt, statt in eine Datei.

## Was ungesichert ist

Geänderte Bytes erscheinen **rot**, bis sie gesichert sind, und der Bereichskopf weist das Dokument als geändert aus. Das Sichern hebt beide Kennzeichen auf.

## Wenn die Datei sich währenddessen ändert

ByteRipper beobachtet die geöffnete Datei. Schreibt ein anderes Programm sie neu — etwa eine Programmiersoftware, die den Baustein in denselben Pfad ausliest —, wird das erkannt und gemeldet, statt dass ein späteres Sichern den neuen Inhalt stillschweigend überschreibt.

## Dokumente ohne Datei

Manche Dokumente haben ihrer Natur nach weder Namen noch Pfad, weshalb ⌘S fragt, wohin sie geschrieben werden sollen:

- **Ablage ▸ Neue Datei** (⌘N).
- Das Ergebnis eines [[topic:join-duplicate|Zusammenfügens]]: Zwei Dumps zu verbinden ergibt ein *neues* Image, das ⌘S nicht über eine der Hälften schreiben darf.
- Das Ergebnis von **Duplizieren**.
- Ein Fragment, das aus einem Image geholt wurde.

! **Sichern unter…** schreibt das bearbeitete Image in eine neue Datei und lässt die gelesene Datei unverändert. Ist der ursprüngliche Dump überschrieben, lässt er sich mit den Mitteln des Programms nicht wiederherstellen.
