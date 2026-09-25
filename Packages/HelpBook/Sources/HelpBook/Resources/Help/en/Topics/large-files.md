# Large Dumps

> Nothing is loaded into memory whole, so a big image opens as fast as a small one.

ByteRipper reads a file in blocks and keeps only what it is showing, plus a bounded cache. A 32 MB SPI dump and a 2 GB image open the same way: immediately, with the first rows on screen before the rest of the file has been touched.

What follows from that:

- **Opening is instant**, whatever the size. If an open is slow, the file is on a slow disk or a network share, not too big.
- **Editing does not rewrite the file.** Your changes are held apart from the file on disk until you save — which is why the changed bytes are shown in red until then.
- **Whole-file work is done in the background.** A full comparison, a search over the whole dump, a firmware parse: the window stays usable and a progress line appears at the bottom of the pane. It can be cancelled.
- **The visible comparison is immediate.** What you can see is compared as you scroll, even while the full count of differences is still being worked out.

For a bench that means the file size is not a reason to choose a different tool. A full 16 MB SPI dump with an ME region, a full 64 MB dual-chip read, an eMMC extract — all of them are ordinary.

See also: [[topic:minimap|The minimap]], which is how you see the shape of a big file at once.
