// The EC pass: an ITE EC firmware image (module kind EC, family ite-nds32)
// made ready for a review, before Ghidra's analysis.
//
//   analyzeHeadless <project> <name> -import <image> -processor NDS32:LE:32:default
//       -loader BinaryLoader -loader-baseAddr 0 -preScript ApplyItEc.java <ec-layout.json>
//
// The server (GhidraHost.createEC) reads the image's layout in Swift
// (Packages/ECImage) and writes it, with the register and interrupt maps of
// Skills/ghidra-ec/reference, into the JSON this script reads. The script
// only applies it:
//
// - blocks: `flash` [0, extent) r-x, `eflash_data` [extent,
//   host_update_size) rw uninitialised, `ram` rw, `regs` rw volatile;
// - functions at the vectors: ResetEntry, Exc_<name>, Isr_Lvl<N> (N is the
//   level the stub loads into r0: vector 9 + N); IsrCommonEntry, the level
//   handlers IsrLevelHandler<N>, IsrDispatch, and one Isr_Irq<NNN> per INTC
//   interrupt (a handler several interrupts share: Isr_IrqShared_<lowest>);
// - labels: Signature, VersionString, DataInitSource/DataInitTarget,
//   IsrLevelTable, IsrIrqTable, main, the registers with data of their width,
//   and the module's known labels.
//
// Nothing semantic beyond that: what a handler does is the review's. The
// last line it prints, `ApplyItEc done`, is what the server checks for.

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.address.AddressSpace;
import ghidra.program.model.data.ArrayDataType;
import ghidra.program.model.data.ByteDataType;
import ghidra.program.model.data.DWordDataType;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.PointerDataType;
import ghidra.program.model.data.StringDataType;
import ghidra.program.model.data.WordDataType;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

public class ApplyItEc extends GhidraScript {
    private AddressSpace space;
    private int functions = 0;
    private int labels = 0;

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) throw new IllegalArgumentException("ApplyItEc.java <ec-layout.json>");
        JsonObject input = JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();
        space = currentProgram.getAddressFactory().getDefaultAddressSpace();
        Memory memory = currentProgram.getMemory();
        if (args.length > 1 && args[1].equals("post")) {
            // After the analysis: the eflash_data block. Made before it, the
            // analysis would reference every constant that falls in it (the
            // timer's 150000 at 0x15424 = 0x249F0) — the very thing
            // flashReferences proves by use instead.
            JsonObject block = eflashDataBlock(currentProgram, input);
            println("ApplyItEc eflash_data: " + block);
            return;
        }

        // The blocks.
        long extent = input.get("extent").getAsLong();
        MemoryBlock flash = memory.getBlock(at(input.get("flash_base").getAsLong()));
        if (flash == null) throw new IllegalStateException("no block at the flash base");
        flash.setName("flash");
        flash.setRead(true);
        flash.setWrite(false);
        flash.setExecute(true);
        if (flash.getSize() != extent) {
            println("ApplyItEc: the flash block is " + flash.getSize() + " bytes, the extent " + extent);
        }
        JsonArray ram = input.getAsJsonArray("ram");
        MemoryBlock ramBlock = memory.createUninitializedBlock("ram", at(ram.get(0).getAsLong()),
            ram.get(1).getAsLong() - ram.get(0).getAsLong(), false);
        ramBlock.setRead(true);
        ramBlock.setWrite(true);
        ramBlock.setExecute(false);
        JsonArray regs = input.getAsJsonArray("regs");
        MemoryBlock regBlock = memory.createUninitializedBlock("regs", at(regs.get(0).getAsLong()),
            regs.get(1).getAsLong() - regs.get(0).getAsLong(), false);
        regBlock.setRead(true);
        regBlock.setWrite(true);
        regBlock.setExecute(false);
        regBlock.setVolatile(true);

        // The header.
        long signature = input.get("signature").getAsLong();
        long version = input.get("version").getAsLong();
        label(signature, "Signature");
        if (signature != version) {
            data(signature, new ArrayDataType(ByteDataType.dataType, 16, 1));
        }
        label(version, "VersionString");
        // Exactly the printable run (ECChipFamily.version): a terminated
        // string would run on over the code that follows it (0xA0 on IT8227E).
        int versionLength = has(input, "version_length") ? input.get("version_length").getAsInt() : 0;
        if (versionLength > 0) data(version, new StringDataType(), versionLength);

        JsonObject layout = input.getAsJsonObject("layout");
        JsonObject startup = layout.has("startup") && layout.get("startup").isJsonObject()
            ? layout.getAsJsonObject("startup") : null;
        if (startup != null) {
            if (has(startup, "dataSource")) {
                label(startup.get("dataSource").getAsLong(), "DataInitSource");
                label(startup.get("dataTarget").getAsLong(), "DataInitTarget");
                int length = startup.get("dataLength").getAsInt();
                data(startup.get("dataSource").getAsLong(), new ArrayDataType(ByteDataType.dataType, length, 1));
            }
        }

        // The vectors and what they reach.
        for (JsonElement each : layout.getAsJsonArray("vectors")) {
            JsonObject vector = each.getAsJsonObject();
            int index = vector.get("index").getAsInt();
            label(index * 4L, String.format("Vector_%02d", index));
            function(vector.get("target").getAsLong(), vector.get("name").getAsString(), null);
        }
        if (startup != null && has(startup, "main")) function(startup.get("main").getAsLong(), "main", null);
        if (has(layout, "commonEntry")) {
            function(layout.get("commonEntry").getAsLong(), "IsrCommonEntry",
                "The entry every interrupt level's stub jumps to, with its level in r0: it calls the level's "
                + "handler from IsrLevelTable.");
        }
        if (has(layout, "levelTable")) {
            label(layout.get("levelTable").getAsLong(), "IsrLevelTable");
            for (JsonElement each : layout.getAsJsonArray("levelHandlers")) {
                JsonObject handler = each.getAsJsonObject();
                data(handler.get("slot").getAsLong(), PointerDataType.dataType);
                function(handler.get("target").getAsLong(), "IsrLevelHandler" + handler.get("number").getAsInt(), null);
            }
        }
        if (has(layout, "dispatcher")) {
            function(layout.get("dispatcher").getAsLong(), "IsrDispatch",
                "Reads the INTC's vector register (IVCT) and calls the handler of interrupt IVCT - 0x10 "
                + "from IsrIrqTable.");
        }
        JsonObject sources = input.has("irq_sources") ? input.getAsJsonObject("irq_sources") : new JsonObject();
        if (has(layout, "irqTable")) {
            label(layout.get("irqTable").getAsLong(), "IsrIrqTable");
            Map<Long, List<Integer>> byTarget = new TreeMap<>();
            for (JsonElement each : layout.getAsJsonArray("irqHandlers")) {
                JsonObject handler = each.getAsJsonObject();
                data(handler.get("slot").getAsLong(), PointerDataType.dataType);
                byTarget.computeIfAbsent(handler.get("target").getAsLong(), k -> new ArrayList<>())
                    .add(handler.get("number").getAsInt());
            }
            for (Map.Entry<Long, List<Integer>> entry : byTarget.entrySet()) {
                List<Integer> irqs = entry.getValue();
                int first = irqs.get(0);
                String plate;
                String name;
                if (irqs.size() == 1) {
                    name = String.format("Isr_Irq%03d", first);
                    String source = sources.has(String.valueOf(first)) ? sources.get(String.valueOf(first)).getAsString() : null;
                    plate = "INTC interrupt " + first
                        + (source != null ? ", source " + source + " (the register map's IT83XX_IRQ_" + source + ")" : "")
                        + ".";
                } else {
                    name = String.format("Isr_IrqShared_%03d", first);
                    StringBuilder list = new StringBuilder();
                    for (int irq : irqs) list.append(list.length() == 0 ? "" : ", ").append(irq);
                    plate = "The handler of " + irqs.size() + " INTC interrupts: " + list + ".";
                }
                function(entry.getKey(), name, plate);
            }
        }

        // The registers.
        int registers = 0;
        if (input.has("registers")) {
            for (JsonElement each : input.getAsJsonArray("registers")) {
                JsonObject register = each.getAsJsonObject();
                long address = register.get("address").getAsLong();
                if (!regBlock.contains(at(address))) continue;
                if (getSymbolAt(at(address)) != null && getSymbolAt(at(address)).getSource() == SourceType.IMPORTED) continue;
                label(address, register.get("name").getAsString());
                int width = register.get("width").getAsInt();
                DataType type = width == 4 ? DWordDataType.dataType : width == 2 ? WordDataType.dataType : ByteDataType.dataType;
                data(address, type);
                String note = register.get("block").getAsString()
                    + (register.has("description") ? ": " + register.get("description").getAsString() : "");
                String status = register.has("status") ? register.get("status").getAsString() : "";
                if (status.equals("unverified")) note += " (IT8320 name, not verified for IT8227E)";
                else if (status.equals("firmware")) note += " (from the firmware: " + register.get("source").getAsString() + ")";
                currentProgram.getListing().setComment(at(address), CommentType.EOL, note);
                registers++;
            }
        }

        if (input.has("known_labels")) {
            for (JsonElement each : input.getAsJsonArray("known_labels")) {
                JsonObject known = each.getAsJsonObject();
                label(known.get("address").getAsLong(), known.get("name").getAsString());
            }
        }
        // The flash past the extent the code points at: the same code the
        // owner's `/v1/ec/reapply` runs on a project made before it was here.
        JsonObject flashRefs = flashReferences(currentProgram, input);
        labels += flashRefs.getAsJsonArray("labels_added").size();
        for (JsonElement each : flashRefs.getAsJsonArray("plates_kept")) {
            println("ApplyItEc: no plate at " + each.getAsJsonObject().get("address").getAsString() + ": "
                    + each.getAsJsonObject().get("why").getAsString());
        }
        // Calls into bytes the analysis left undecoded: a `jral5` through a
        // register the code builds with sethi/ori, whose target the analysis
        // only learns as a reference once the data laid above no longer
        // covers it (0xA0, called from ResetEntry on IT8227E).
        seedCallTargets(memory);
        int based = baseTypes(currentProgram);
        println("ApplyItEc: " + based + " base types in " + BASE_CATEGORY);
        println("ApplyItEc done: " + functions + " functions, " + labels + " labels, " + registers + " registers");
    }

    /**
     * Where the EDK2-style base types of an EC program live: the root, where
     * a review's own `typedef unsigned char UINT8;` lands too, so the two are
     * one type and not `/UINT8` beside another `UINT8` the parser cannot
     * choose between.
     */
    public static final String BASE_CATEGORY = "/";

    /**
     * EDK2's base type names, in the widths NDS32 has (32-bit, so INTN and
     * UINTN are 32 bits), each a typedef of Ghidra's own type: an EC review
     * writes `UINT8`, `BOOLEAN` and `UINTN` as a UEFI review does, and has no
     * EDK2 archive to take them from. `VOID` is not one: the owner reads it as
     * `void` in every signature and type. `BOOL` is the 32-bit `int` C code
     * outside EDK2 uses.
     */
    public static final String[][] BASE_TYPES = {
        {"BOOLEAN", "u1"}, {"BOOL", "s4"},
        {"INT8", "s1"}, {"UINT8", "u1"}, {"INT16", "s2"}, {"UINT16", "u2"},
        {"INT32", "s4"}, {"UINT32", "u4"}, {"INT64", "s8"}, {"UINT64", "u8"},
        {"INTN", "s4"}, {"UINTN", "u4"}, {"CHAR8", "c1"}, {"CHAR16", "u2"},
    };

    /**
     * Adds to the program each of `BASE_TYPES` it does not hold by that name
     * (a type a review brought in under the name is kept), in the caller's
     * transaction; answers how many were added. Run as a module is made, and
     * by the owner on a project made before it was part of that.
     */
    public static int baseTypes(ghidra.program.model.listing.Program program) {
        ghidra.program.model.data.DataTypeManager manager = program.getDataTypeManager();
        ghidra.program.model.data.CategoryPath category = new ghidra.program.model.data.CategoryPath(BASE_CATEGORY);
        int added = 0;
        for (String[] base : BASE_TYPES) {
            java.util.List<DataType> held = new ArrayList<>();
            manager.findDataTypes(base[0], held);
            if (held.stream().anyMatch(type -> type.getName().equals(base[0]))) continue;
            int size = base[1].charAt(1) - '0';
            DataType target = switch (base[1].charAt(0)) {
                case 'c' -> ghidra.program.model.data.CharDataType.dataType;
                case 's' -> ghidra.program.model.data.AbstractIntegerDataType.getSignedDataType(size, manager);
                default -> ghidra.program.model.data.AbstractIntegerDataType.getUnsignedDataType(size, manager);
            };
            manager.resolve(new ghidra.program.model.data.TypedefDataType(category, base[0], target, manager),
                            ghidra.program.model.data.DataTypeConflictHandler.KEEP_HANDLER);
            added++;
        }
        return added;
    }

    /**
     * The flash past the image extent the code points at, from the input's
     * `extent`, `host_update_size` and `refs_past_extent` (the server finds
     * the references in Swift, ECImage's `referencesPastExtent`): a DATA
     * reference from each `from`, so `xrefs` finds the code that uses it; a
     * `FlashRef_<ADDR>` label, no type; and a plate saying what is known of
     * it. Run by this script as a module is made, and by the owner
     * (`/v1/ec/reapply`) on a project made before it was part of that, in
     * the caller's transaction.
     *
     * It only adds: a reference that is there is not added again, a name a
     * place already has (a reviewer's `EflashState_2A600`) is kept, and so is
     * a plate. The answer lists each reference, label and plate added or
     * kept, a kept one with `why`.
     */
    public static JsonObject flashReferences(ghidra.program.model.listing.Program program, JsonObject input) {
        AddressSpace space = program.getAddressFactory().getDefaultAddressSpace();
        var references = program.getReferenceManager();
        SymbolTable symbols = program.getSymbolTable();
        var listing = program.getListing();
        long extent = input.get("extent").getAsLong();
        long hostUpdate = has(input, "host_update_size") ? input.get("host_update_size").getAsLong() : 0;
        JsonObject answer = new JsonObject();
        JsonArray refsAdded = new JsonArray(), refsKept = new JsonArray();
        JsonArray labelsAdded = new JsonArray(), labelsKept = new JsonArray();
        JsonArray platesAdded = new JsonArray(), platesKept = new JsonArray();
        java.util.Set<Long> placed = new java.util.HashSet<>();
        JsonArray given = has(input, "refs_past_extent") ? input.getAsJsonArray("refs_past_extent") : new JsonArray();
        for (JsonElement each : given) {
            long address = each.getAsJsonObject().get("address").getAsLong();
            long from = each.getAsJsonObject().get("from").getAsLong();
            Address to = space.getAddress(address);
            Address source = space.getAddress(from);
            JsonObject reference = new JsonObject();
            reference.addProperty("from", String.format("0x%X", from));
            reference.addProperty("address", String.format("0x%X", address));
            boolean there = false;
            for (var held : references.getReferencesFrom(source)) there |= held.getToAddress().equals(to);
            if (there) {
                reference.addProperty("why", "the reference is there");
                refsKept.add(reference);
            } else {
                references.addMemoryReference(source, to, ghidra.program.model.symbol.RefType.DATA,
                    SourceType.IMPORTED, ghidra.program.model.listing.CodeUnit.MNEMONIC);
                refsAdded.add(reference);
            }
            if (!placed.add(address)) continue;

            String name = String.format("FlashRef_%X", address);
            JsonObject label = new JsonObject();
            label.addProperty("address", String.format("0x%X", address));
            var primary = symbols.getPrimarySymbol(to);
            if (primary != null && !primary.isDynamic()) {
                label.addProperty("name", primary.getName());
                label.addProperty("why", primary.getName().equals(name) ? "the label is there"
                    : "the place is named " + primary.getName() + ": the name is kept");
                labelsKept.add(label);
            } else {
                try {
                    symbols.createLabel(to, name, SourceType.IMPORTED).setPrimary();
                    label.addProperty("name", name);
                    labelsAdded.add(label);
                } catch (Exception e) {
                    label.addProperty("why", "no label: " + e.getMessage());
                    labelsKept.add(label);
                }
            }

            JsonObject plate = new JsonObject();
            plate.addProperty("address", String.format("0x%X", address));
            String held = null;
            try {
                held = listing.getComment(CommentType.PLATE, to);
            } catch (Exception e) {
                held = null;
            }
            if (held != null && !held.isEmpty()) {
                plate.addProperty("why", "the place has a plate: it is kept");
                platesKept.add(plate);
                continue;
            }
            try {
                // Only what this module's bytes and family say: the plate
                // (begins with FLASH_REF_PLATE, which a rejection looks for)
                // is keyed by the module and shows in every dump.
                String rewrite = hostUpdate > 0 && address < hostUpdate
                    ? String.format(" A host update (host_update_size 0x%X) rewrites [0x%X, 0x%X) from the host's copy.", hostUpdate, extent, hostUpdate)
                    : " Outside the range a host update rewrites.";
                listing.setComment(to, CommentType.PLATE, String.format(
                    FLASH_REF_PLATE + " (0x%X): the EC's flash data area, not part of this module."
                    + " Its contents are whatever the EC wrote there at run time.%s"
                    + " The meaning comes from the code that reads or writes it.", extent, rewrite));
                platesAdded.add(plate);
            } catch (Exception e) {
                plate.addProperty("why", "no plate: " + e.getMessage());
                platesKept.add(plate);
            }
        }
        rejectFlashReferences(program, input, answer);
        answer.add("references_added", refsAdded);
        answer.add("references_kept", refsKept);
        answer.add("labels_added", labelsAdded);
        answer.add("labels_kept", labelsKept);
        answer.add("plates_added", platesAdded);
        answer.add("plates_kept", platesKept);
        return answer;
    }

    /** How the plate `flashReferences` writes begins. */
    static final String FLASH_REF_PLATE = "Referenced past the image extent";

    /**
     * The places a project made under the earlier rule labelled that the
     * input's `refs_past_extent` no longer holds (0x249F0 on IT8227E: a
     * timer's 150000 ms, not an address): the label goes, with the DATA
     * references this pass made to it and its plate, only while it is still
     * this pass's — named `FlashRef_<ADDR>` and IMPORTED, the plate still
     * beginning with FLASH_REF_PLATE. A renamed place, or one a review
     * commented, is kept and listed with `why`. Adds `labels_removed`,
     * `references_removed`, `plates_removed` and `rejected_kept` to `answer`.
     */
    static void rejectFlashReferences(ghidra.program.model.listing.Program program, JsonObject input, JsonObject answer) {
        AddressSpace space = program.getAddressFactory().getDefaultAddressSpace();
        var references = program.getReferenceManager();
        var listing = program.getListing();
        java.util.Set<Long> given = new java.util.HashSet<>();
        if (has(input, "refs_past_extent")) {
            for (JsonElement each : input.getAsJsonArray("refs_past_extent")) {
                given.add(each.getAsJsonObject().get("address").getAsLong());
            }
        }
        JsonArray labelsRemoved = new JsonArray(), refsRemoved = new JsonArray(),
            platesRemoved = new JsonArray(), kept = new JsonArray();
        // Every place past the extent this pass referenced (IMPORTED DATA).
        long extent = input.get("extent").getAsLong();
        java.util.TreeSet<Address> places = new java.util.TreeSet<>();
        var destinations = references.getReferenceDestinationIterator(
            new AddressSet(space.getAddress(extent), space.getMaxAddress()), true);
        while (destinations.hasNext()) places.add(destinations.next());
        var symbols = program.getSymbolTable();
        for (Address to : places) {
            long address = to.getOffset();
            if (given.contains(address)) continue;
            List<ghidra.program.model.symbol.Reference> ours = new ArrayList<>();
            for (var reference : references.getReferencesTo(to)) {
                if (reference.getSource() == SourceType.IMPORTED
                    && reference.getReferenceType() == ghidra.program.model.symbol.RefType.DATA) ours.add(reference);
            }
            if (ours.isEmpty()) continue;
            String where = String.format("0x%X", address);
            String name = String.format("FlashRef_%X", address);
            var primary = symbols.getPrimarySymbol(to);
            if (primary == null || primary.isDynamic() || !primary.getName().equals(name)
                || primary.getSource() != SourceType.IMPORTED) {
                JsonObject note = new JsonObject();
                note.addProperty("address", where);
                note.addProperty("why", (primary == null || primary.isDynamic() ? "no FlashRef_ label"
                    : "named " + primary.getName() + " by a review") + ": kept, with its references");
                kept.add(note);
                continue;
            }
            for (var reference : ours) {
                JsonObject removed = new JsonObject();
                removed.addProperty("from", String.format("0x%X", reference.getFromAddress().getOffset()));
                removed.addProperty("address", where);
                references.delete(reference);
                refsRemoved.add(removed);
            }
            String plate = listing.getComment(CommentType.PLATE, to);
            if (plate != null && plate.startsWith(FLASH_REF_PLATE)) {
                listing.setComment(to, CommentType.PLATE, null);
                platesRemoved.add(where);
            }
            JsonObject label = new JsonObject();
            label.addProperty("address", where);
            label.addProperty("name", primary.getName());
            primary.delete();
            labelsRemoved.add(label);
        }
        answer.add("labels_removed", labelsRemoved);
        answer.add("references_removed", refsRemoved);
        answer.add("plates_removed", platesRemoved);
        answer.add("rejected_kept", kept);
    }

    /** The name of the block over the flash data area past the image. */
    public static final String EFLASH_DATA_BLOCK = "eflash_data";

    /**
     * The flash past the image, from the end of the `flash` block to the end
     * of what a host update writes (`host_update_size`, 0x2C000 on IT8227E:
     * the EC's settings and log live there): an uninitialised block, read and
     * write, not executable, so a review can type data and write plates
     * there. Its bytes are not the module's — the BIOS copy holds FF, the
     * chip what the EC wrote — so none are given. Added when absent, in the
     * caller's transaction; the answer says whether it was added, kept, or
     * why there is none.
     */
    public static JsonObject eflashDataBlock(ghidra.program.model.listing.Program program, JsonObject input) {
        JsonObject answer = new JsonObject();
        Memory memory = program.getMemory();
        MemoryBlock held = memory.getBlock(EFLASH_DATA_BLOCK);
        if (held != null) {
            answer.addProperty("block", "kept");
            answer.addProperty("start", String.format("0x%X", held.getStart().getOffset()));
            answer.addProperty("end", String.format("0x%X", held.getEnd().getOffset() + 1));
            return answer;
        }
        MemoryBlock flash = memory.getBlock("flash");
        long end = has(input, "host_update_size") ? input.get("host_update_size").getAsLong() : 0;
        if (flash == null || end <= flash.getEnd().getOffset() + 1) {
            answer.addProperty("block", "none");
            answer.addProperty("why", flash == null ? "no flash block" : "no flash past the image to cover");
            return answer;
        }
        long start = flash.getEnd().getOffset() + 1;
        try {
            MemoryBlock block = memory.createUninitializedBlock(EFLASH_DATA_BLOCK,
                program.getAddressFactory().getDefaultAddressSpace().getAddress(start), end - start, false);
            block.setRead(true);
            block.setWrite(true);
            block.setExecute(false);
            block.setComment("The EC's flash past the image: settings and log written at run time; no bytes here.");
            answer.addProperty("block", "added");
        } catch (Exception e) {
            answer.addProperty("block", "none");
            answer.addProperty("why", e.getMessage());
            return answer;
        }
        answer.addProperty("start", String.format("0x%X", start));
        answer.addProperty("end", String.format("0x%X", end));
        return answer;
    }

    private void seedCallTargets(Memory memory) throws Exception {
        java.util.Set<Address> targets = new java.util.TreeSet<>();
        var references = currentProgram.getReferenceManager().getReferenceIterator(currentProgram.getMinAddress());
        while (references.hasNext()) {
            var reference = references.next();
            if (!reference.getReferenceType().isCall()) continue;
            Address target = reference.getToAddress();
            MemoryBlock block = memory.getBlock(target);
            if (block == null || !block.isExecute() || !block.isInitialized()) continue;
            if (getInstructionAt(target) != null || getDataContaining(target) != null) continue;
            targets.add(target);
        }
        // `sethi rX,hi; ori rX,rX,lo; jral5 rX`: the call target is
        // hi << 12 | lo. The analysis makes no reference of it when the
        // target was not code, so the call is found here and referenced.
        var instructions = currentProgram.getListing().getInstructions(true);
        while (instructions.hasNext()) {
            var call = instructions.next();
            if (!call.getMnemonicString().startsWith("jral")) continue;
            var low = call.getPrevious();
            var high = low == null ? null : low.getPrevious();
            if (low == null || high == null || !low.getMnemonicString().equals("ori")
                || !high.getMnemonicString().equals("sethi")) continue;
            Object[] target = call.getOpObjects(0);
            Object[] lowOps = low.getOpObjects(0), lowSource = low.getOpObjects(1), highOps = high.getOpObjects(0);
            if (target.length != 1 || lowOps.length != 1 || lowSource.length != 1 || highOps.length != 1
                || !target[0].equals(lowOps[0]) || !target[0].equals(lowSource[0]) || !target[0].equals(highOps[0])) continue;
            var hi = high.getScalar(1);
            var lo = low.getScalar(2);
            if (hi == null || lo == null) continue;
            Address to;
            try {
                to = at((hi.getUnsignedValue() << 12) | lo.getUnsignedValue());
            } catch (Exception e) {
                continue;
            }
            MemoryBlock block = memory.getBlock(to);
            if (block == null || !block.isExecute() || !block.isInitialized()) continue;
            boolean referenced = false;
            for (var each : call.getReferencesFrom()) referenced |= each.getToAddress().equals(to);
            if (!referenced) {
                currentProgram.getReferenceManager().addMemoryReference(call.getAddress(), to,
                    ghidra.program.model.symbol.RefType.COMPUTED_CALL, SourceType.ANALYSIS, 0);
            }
            if (getInstructionAt(to) == null && getDataContaining(to) == null) targets.add(to);
        }
        for (Address target : targets) {
            if (getInstructionAt(target) == null) {
                new DisassembleCommand(new AddressSet(target), null, true).applyTo(currentProgram, monitor);
            }
            if (getInstructionAt(target) != null && getFunctionAt(target) == null
                && currentProgram.getFunctionManager().getFunctionContaining(target) == null) {
                if (createFunction(target, null) != null) functions++;
            }
        }
    }

    /**
     * `standby` sites made right on a Ghidra whose NDS32 language carries
     * nds32-standby-1 (Scripts/make-patched-ghidra.sh). Stock Ghidra models
     * standby as a branch to itself, so a program analysed on it has no code
     * after a standby and its function ends there; the patched language
     * reads the same bytes as an instruction that goes on. Here the code
     * after each site is disassembled, the function around it gets its body
     * again and loses a no-return mark it no longer earns, and a call to it
     * that was cut as a terminator goes on too — then its caller the same
     * way. Names, comments and types are not touched; a second run changes
     * nothing. Only for a Ghidra with the patch: on stock, standby still
     * ends the flow and this would undo nothing.
     */
    public static JsonObject standbySites(ghidra.program.model.listing.Program program,
                                          ghidra.util.task.TaskMonitor monitor) throws Exception {
        var listing = program.getListing();
        JsonArray sites = new JsonArray(), disassembled = new JsonArray(), bodies = new JsonArray(),
            returning = new JsonArray(), calls = new JsonArray();
        java.util.ArrayDeque<Function> work = new java.util.ArrayDeque<>();
        java.util.Set<Address> queued = new java.util.HashSet<>();
        List<ghidra.program.model.listing.Instruction> found = new ArrayList<>();
        for (var instruction : listing.getInstructions(true)) {
            if (instruction.getMnemonicString().equalsIgnoreCase("standby")) found.add(instruction);
        }
        for (var instruction : found) {
            Address at = instruction.getAddress();
            sites.add(String.format("0x%X", at.getOffset()));
            Address next = instruction.getFallThrough();
            if (next == null) continue; // the language is stock's: nothing to do
            if (listing.getInstructionAt(next) == null && listing.getDefinedDataAt(next) == null) {
                new DisassembleCommand(next, null, true).applyTo(program, monitor);
                if (listing.getInstructionAt(next) != null) disassembled.add(String.format("0x%X", next.getOffset()));
            }
            Function around = program.getFunctionManager().getFunctionContaining(at);
            if (around != null && queued.add(around.getEntryPoint())) work.add(around);
        }
        while (!work.isEmpty()) {
            Function function = work.poll();
            var before = function.getBody();
            ghidra.app.cmd.function.CreateFunctionCmd.fixupFunctionBody(program, listing.getInstructionAt(function.getEntryPoint()), monitor);
            if (!function.getBody().equals(before)) {
                bodies.add(String.format("0x%X", function.getEntryPoint().getOffset()));
            }
            if (function.hasNoReturn() && returns(program, function)) {
                function.setNoReturn(false);
                returning.add(String.format("0x%X", function.getEntryPoint().getOffset()));
            }
            if (function.hasNoReturn()) continue;
            for (var reference : program.getReferenceManager().getReferencesTo(function.getEntryPoint())) {
                if (!reference.getReferenceType().isCall()) continue;
                var call = listing.getInstructionAt(reference.getFromAddress());
                if (call == null) continue;
                boolean changed = false;
                if (call.getFlowOverride() == ghidra.program.model.listing.FlowOverride.CALL_RETURN
                    || call.getFlowOverride() == ghidra.program.model.listing.FlowOverride.RETURN) continue;
                if (call.getFallThrough() == null && call.getFlowOverride() != ghidra.program.model.listing.FlowOverride.NONE) {
                    call.setFlowOverride(ghidra.program.model.listing.FlowOverride.NONE);
                    changed = true;
                }
                Address next = call.getFallThrough();
                if (next != null && listing.getInstructionAt(next) == null && listing.getDefinedDataAt(next) == null) {
                    new DisassembleCommand(next, null, true).applyTo(program, monitor);
                    changed |= listing.getInstructionAt(next) != null;
                }
                if (!changed) continue;
                calls.add(String.format("0x%X", call.getAddress().getOffset()));
                Function caller = program.getFunctionManager().getFunctionContaining(call.getAddress());
                if (caller != null && queued.add(caller.getEntryPoint())) work.add(caller);
            }
        }
        JsonObject answer = new JsonObject();
        answer.add("standby_sites", sites);
        answer.add("standby_disassembled", disassembled);
        answer.add("standby_bodies", bodies);
        answer.add("standby_returning", returning);
        answer.add("standby_calls", calls);
        return answer;
    }

    /** Whether a function's body holds a return. */
    private static boolean returns(ghidra.program.model.listing.Program program, Function function) {
        for (var instruction : program.getListing().getInstructions(function.getBody(), true)) {
            var flow = instruction.getFlowType();
            if (flow.isTerminal() && !flow.isCall() && !flow.isJump()) return true;
        }
        return false;
    }

    private static boolean has(JsonObject object, String key) {
        return object.has(key) && !object.get(key).isJsonNull();
    }

    private Address at(long offset) {
        return space.getAddress(offset);
    }

    private void label(long offset, String name) throws Exception {
        SymbolTable symbols = currentProgram.getSymbolTable();
        symbols.createLabel(at(offset), name, SourceType.IMPORTED).setPrimary();
        labels++;
    }

    private void data(long offset, DataType type) {
        try {
            DataUtilities.createData(currentProgram, at(offset), type, -1,
                DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
        } catch (Exception e) {
            println("ApplyItEc: no " + type.getName() + " at 0x" + Long.toHexString(offset) + ": " + e.getMessage());
        }
    }

    private void data(long offset, DataType type, int length) {
        try {
            DataUtilities.createData(currentProgram, at(offset), type, length,
                DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
        } catch (Exception e) {
            println("ApplyItEc: no " + type.getName() + " at 0x" + Long.toHexString(offset) + ": " + e.getMessage());
        }
    }

    private void function(long offset, String name, String plate) throws Exception {
        Address entry = at(offset);
        if (getInstructionAt(entry) == null) {
            new DisassembleCommand(new AddressSet(entry), null, true).applyTo(currentProgram, monitor);
        }
        Function function = getFunctionAt(entry);
        if (function == null) function = createFunction(entry, name);
        if (function == null) {
            label(offset, name);
            println("ApplyItEc: no function at 0x" + Long.toHexString(offset) + " (" + name + ")");
            return;
        }
        function.setName(name, SourceType.IMPORTED);
        if (plate != null) function.setComment(plate);
        functions++;
    }
}
