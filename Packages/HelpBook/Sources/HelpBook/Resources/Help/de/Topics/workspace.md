@source-sha e525380aba9627ee9563981885ff4fa288d5b29320c52f6586f0cd8d8488c4c7
# Der Arbeitsbereich

> Bei eingeschalteter Einstellung öffnet ByteRipper beim Start, was beim Beenden geöffnet war.

Die Einstellung heißt **Arbeitsbereich beim Start wiederherstellen** und befindet sich in den [[topic:settings|Einstellungen ▸ Allgemein]]. Nach der Installation ist sie ausgeschaltet: Am Reparaturplatz ist jeder Auftrag eine andere Platine, und Dumps eines früheren Auftrags, die sich von selbst öffnen, wären hinderlich.

## Was wiederhergestellt wird

- Die Fenster und ihre Tabs in ihrer Reihenfolge, Größe und Lage; vorn liegt derselbe Tab.
- In jedem Tab File A und File B, der aktive Bereich und die Lage der Trennlinie zwischen ihnen.
- In jedem Bereich die Adresse in der obersten Bildschirmzeile, Cursor und Auswahl, die Hex- oder Textspalte und der Einfügemodus.
- Die [[topic:bookmarks|Lesezeichen]] und die [[topic:segments|Segmente]]: Schnitte, Namen und die Verknüpfungen der Segmente mit den Dateien, aus denen sie zusammengefügt wurden.
- Die [[topic:fragments|Fragment-Bereiche]] samt dem, der vorn lag, sowie Teile, die in eigene Tabs verschoben wurden. Ein Teil wird nicht als Bytes gespeichert, sondern erneut aus seiner Datei entnommen; er zeigt daher deren aktuellen Inhalt und lässt sich weiterhin zurückschreiben, gleich in welchem Tab oder Fenster diese Datei liegt.
- **Nie gesicherte Dokumente** — eine neue Datei, ein Zusammenfügen, ein Duplikat, auch wenn es einen Namen erhalten hat — mit ihren Bytes und weiterhin ungesichert, sowie Teile mit Änderungen, die noch nicht in ihre Datei zurückgeschrieben sind, samt diesen Änderungen. Sie werden während der Arbeit neben dem Arbeitsbereich aufbewahrt, gehen daher auch bei einem unplanmäßigen Ende nicht verloren, und beim Beenden fragt das Programm nicht nach ihnen.
- Das [[topic:notes|Anmerkungen-Fenster]] an seinem Platz zwischen den Tabs oder als eigenes Fenster, mit den Karten, die ausgewählt waren.
- Die [[topic:minimap|Minimap]], die Suchleiste mit ihrem Muster sowie der Werkzeugbereich mit dem darin gewählten Knoten oder der gewählten Zeile und den geöffneten Zweigen des UEFI-Baums.

## Was nicht wiederhergestellt wird

- **Der Widerrufsverlauf.** Er gehört zu der Sitzung, in der die Änderungen vorgenommen wurden.
- **Ungesicherte Änderungen an einer Datei auf dem Datenträger.** Beim Beenden fragt das Programm wie bisher, ob sie gesichert oder verworfen werden sollen; das ist die einzige Frage, die es stellt. Endet das Programm unplanmäßig, gehen solche Änderungen verloren; die Datei selbst, ihre Position und ihre Lesezeichen werden vom Datenträger wiederhergestellt.
- Die Verbindung eines Teils mit seiner Datei, wenn diese Datei fehlt oder sich geändert hat: Der Teil kehrt mit seinen Änderungen als nie gesichertes Dokument zurück.
- Der Verlauf von Zurück / Vorwärts und die Ergebnisse von Search All.
- Einstellungen wie Schrift, Wortbreite und Anordnung der Bereiche. Sie werden getrennt gespeichert und gelten ohnehin.

## Wann der Arbeitsbereich geschrieben wird

Fortlaufend: alle paar Sekunden, solange das Programm im Vordergrund ist, beim Wechsel in den Hintergrund, beim Schließen eines Fensters und beim Beenden, nachdem die Fragen zu ungesicherten Änderungen an Dateien auf dem Datenträger beantwortet sind. Wird das letzte Fenster von Hand geschlossen, ist der Arbeitsbereich leer, und der nächste Start öffnet ein leeres Fenster. Das Ausschalten der Einstellung löscht den gespeicherten Arbeitsbereich.

Der Arbeitsbereich liegt in `~/Library/Application Support/ByteRipper/Workspace` und verlässt diesen Mac nicht.

## Geänderte und fehlende Dateien

Beim Start wird jede Datei mit der Größe und dem Änderungsdatum verglichen, die sie hatte, als der Arbeitsbereich geschrieben wurde.

- Eine Datei, die nicht mehr unter ihrem Pfad liegt, wird nicht geöffnet.
- Eine geänderte Datei wird geöffnet. Ist sie kürzer geworden, gehen Cursor und Bildschirm auf ihre letzte Adresse, und Lesezeichen hinter ihrem Ende werden entfernt. Ihre Segmente, ihre Teile und der Zustand ihres Werkzeugbereichs werden nicht wiederhergestellt: Sie beziehen sich auf andere Bytes und würden auf falsche Stellen zeigen.

In beiden Fällen nennt eine Meldung nach der Wiederherstellung die betroffenen Dateien.

## Eine Datei aus dem Finder öffnen

Wird ByteRipper durch das Öffnen einer Datei im Finder gestartet, wird zuerst der Arbeitsbereich wiederhergestellt, und die Datei öffnet sich in einem neuen Tab. Eine Datei, die im Arbeitsbereich bereits geöffnet ist, wird nicht ein zweites Mal geöffnet: Ihr Tab wird nach vorn geholt.
