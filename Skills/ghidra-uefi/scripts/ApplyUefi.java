// Give an analyzed UEFI module the names and types its source had.
//
//   analyzeHeadless ... -postScript ApplyUefi.java <uefi.gdt> <guids.tsv> <pei|dxe> \
//                       -postScript ExportCode.java out.json
//
// Ghidra reads a PEIM or a DXE driver as anonymous code: FUN_0000f6e0,
// param_2, (**(code **)(lVar1 + 0x58))(). What a reader needs is what EDK2
// wrote — gBS->LocateProtocol (&gEfiPciIoProtocolGuid, NULL, &PciIo). Most of it
// can be recovered from the structure the specifications fix, without guessing:
//
//  1. Every 16 bytes that are a GUID the catalogue names become an EFI_GUID
//     called by that name (gEfiPciIoProtocolGuid).
//  2. The entry point gets the signature the phase defines: ImageHandle and
//     SystemTable for a DXE driver, FileHandle and PeiServices for a PEIM.
//  3. Those types follow the arguments: a function called with SystemTable or
//     PeiServices gets that parameter's type, and so on down the calls.
//  4. A global written from them is named and typed: gST, gBS, gRT,
//     gImageHandle, gSmst — the names the EDK2 libraries use.
//  5. With those types, a call through a service table names its field. A
//     LocateProtocol, HandleProtocol, OpenProtocol or LocatePpi gives its
//     result the protocol's type and name; an InstallProtocolInterface or an
//     InstallPpi names the interface it installs; a NotifyPpi, CreateEventEx or
//     RegisterProtocolNotify names the function it registers.
//  6. A function that hands DEBUG a "%a" format and an identifier is named by
//     that identifier: EDK2 passes __FUNCTION__ there.
//
// Every name this pass gives is SourceType.ANALYSIS, and why it was given is
// kept in the program's "ByteRipper.nameReason" property, which ExportCode
// writes beside the name: a reader sees which names are the module's own
// evidence and which are Ghidra's FUN_ placeholders.
//
// <uefi.gdt> is `uefi_X64.gdt` or `uefi_Ia32.gdt` (BuildUefiTypes.java);
// <guids.tsv> is `<32 hex digits of the GUID's bytes>\t<name>` per line, the
// names with their g…Guid spelling (the server's `UEFITypes` writes it).
// @category ByteRipper

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeConflictHandler;
import ghidra.program.model.data.DataTypeManager;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.FileDataTypeManager;
import ghidra.program.model.data.FunctionDefinition;
import ghidra.program.model.data.ParameterDefinition;
import ghidra.program.model.data.ParameterDefinitionImpl;
import ghidra.program.model.data.VoidDataType;
import ghidra.program.model.data.Pointer;
import ghidra.program.model.data.PointerDataType;
import ghidra.program.model.data.Structure;
import ghidra.program.model.data.DataTypeComponent;
import ghidra.program.model.data.TypeDef;
import ghidra.program.model.data.Undefined;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Parameter;
import ghidra.program.model.listing.ParameterImpl;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighFunctionDBUtil;
import ghidra.program.model.pcode.HighParam;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.pcode.HighVariable;
import ghidra.program.model.pcode.PcodeOp;
import ghidra.program.model.pcode.PcodeOpAST;
import ghidra.program.model.pcode.Varnode;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.util.StringPropertyMap;

public class ApplyUefi extends GhidraScript {

    /// The property ExportCode reads a name's reason from.
    static final String REASON = "ByteRipper.nameReason";

    private FileDataTypeManager archive;
    private final Map<String, DataType> archiveTypes = new HashMap<>();
    private final Map<String, String> guidNames = new HashMap<>();
    private final Map<Address, String> guidAt = new HashMap<>();
    private StringPropertyMap reasons;
    private DecompInterface decompiler;
    private Function entry;
    private boolean pei;
    private int named, typedParameters, typedGlobals, typedLocals;

    /// The types that follow the arguments down the calls, and the global a
    /// value of that type is called by when the module keeps one.
    private static final Map<String, String> TRACKED = Map.of(
        "EFI_SYSTEM_TABLE*", "gST",
        "EFI_BOOT_SERVICES*", "gBS",
        "EFI_RUNTIME_SERVICES*", "gRT",
        "EFI_PEI_SERVICES**", "gPeiServices",
        "EFI_MM_SYSTEM_TABLE*", "gMmst",
        "EFI_SMM_SYSTEM_TABLE2*", "gSmst");

    private static final String ZERO_GUID = "0".repeat(32);
    private static final String ONES_GUID = "F".repeat(32);

    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]{2,63}");

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3) {
            println("usage: ApplyUefi.java <uefi.gdt> <guids.tsv> <pei|dxe>");
            return;
        }
        pei = args[2].equalsIgnoreCase("pei");
        archive = FileDataTypeManager.openFileArchive(new File(args[0]), false);
        try {
            Iterator<DataType> all = archive.getAllDataTypes();
            while (all.hasNext()) {
                DataType type = all.next();
                archiveTypes.putIfAbsent(type.getName(), type);
            }
            readGuids(new File(args[1]));
            try {
                reasons = currentProgram.getUsrPropertyManager().createStringPropertyMap(REASON);
            } catch (Exception exists) {
                reasons = currentProgram.getUsrPropertyManager().getStringPropertyMap(REASON);
            }

            decompiler = new DecompInterface();
            decompiler.toggleCCode(false);
            decompiler.toggleSyntaxTree(true);
            decompiler.openProgram(currentProgram);

            declareFirstPair("InstallMultipleProtocolInterfaces");
            declareFirstPair("UninstallMultipleProtocolInterfaces");
            dropThisCall();
            labelGuids();
            typeEntry();
            propagateParameters();
            nameGlobals();
            followServiceCalls();
            nameFromDebugStrings();
        } finally {
            if (decompiler != null) decompiler.dispose();
            archive.close();
        }
        println(String.format(
            "ApplyUefi: %d GUIDs, %d parameters, %d globals, %d locals typed; %d functions named",
            guidAt.size(), typedParameters, typedGlobals, typedLocals, named));
        // The signatures and types set here schedule Ghidra's own analysis
        // again (stack frames, parameter ids). Run it to the end now, so what
        // the export reads in this run is the program a kept project saves:
        // the batch artifact and an owner's publish of the same program agree.
        analyzeChanges(currentProgram);
    }

    // MARK: - Types and GUIDs

    /// A type from the archive, resolved into the program with what it needs.
    private DataType type(String name) {
        DataType type = archiveTypes.get(name);
        if (type == null) return null;
        return currentProgram.getDataTypeManager().resolve(type, DataTypeConflictHandler.DEFAULT_HANDLER);
    }

    private DataType pointer(DataType type, int depth) {
        DataTypeManager manager = currentProgram.getDataTypeManager();
        DataType result = type;
        for (int i = 0; i < depth; i++) result = new PointerDataType(result, manager);
        return result;
    }

    /// `EFI_SYSTEM_TABLE*`, `EFI_PEI_SERVICES**`: the name a type is tracked
    /// by, through pointers and the `_EFI_…` struct a typedef names.
    static String key(DataType type) {
        StringBuilder stars = new StringBuilder();
        while (type instanceof Pointer) {
            stars.append('*');
            type = ((Pointer) type).getDataType();
            if (type == null) return "";
        }
        String name = type.getName();
        if (name.startsWith("_")) name = name.substring(1);
        return name + stars;
    }

    private void readGuids(File file) throws Exception {
        try (BufferedReader reader = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = reader.readLine()) != null) {
                int tab = line.indexOf('\t');
                if (tab != 32) continue;
                guidNames.putIfAbsent(line.substring(0, 32).toUpperCase(), line.substring(tab + 1).trim());
            }
        }
    }

    /// Every four-byte-aligned 16 bytes the catalogue names, outside the
    /// instructions, becomes an EFI_GUID under that name.
    private void labelGuids() throws Exception {
        DataType guid = type("EFI_GUID");
        if (guid == null || guidNames.isEmpty()) return;
        Memory memory = currentProgram.getMemory();
        for (MemoryBlock block : memory.getBlocks()) {
            if (!block.isInitialized() || block.getSize() > (64L << 20)) continue;
            byte[] bytes = new byte[(int) block.getSize()];
            try {
                block.getBytes(block.getStart(), bytes);
            } catch (Exception error) {
                continue;
            }
            for (int at = 0; at + 16 <= bytes.length; at += 4) {
                String key = hex(bytes, at, 16);
                // All zeros is gEfiPartTypeUnusedGuid to EDK2 and gZeroGuid to
                // the catalogue — and is also every zeroed global. All ones is
                // erased flash. Neither is evidence of a GUID.
                if (key.equals(ZERO_GUID) || key.equals(ONES_GUID)) continue;
                String name = guidNames.get(key);
                if (name == null) continue;
                Address address = block.getStart().add(at);
                if (currentProgram.getListing().getInstructionContaining(address) != null) continue;
                try {
                    DataUtilities.createData(currentProgram, address, guid, -1,
                        DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
                } catch (Exception taken) {
                    continue;
                }
                if (label(address, name, "the GUID's bytes are " + name + " in the GUID catalogue")) {
                    guidAt.put(address, name);
                }
            }
        }
    }

    private static String hex(byte[] bytes, int at, int count) {
        StringBuilder builder = new StringBuilder(count * 2);
        for (int i = 0; i < count; i++) builder.append(String.format("%02X", bytes[at + i] & 0xFF));
        return builder.toString();
    }

    /// The GUID at an address: one the scan labelled, or 16 bytes the
    /// catalogue names (a GUID inside a structure the scan's alignment missed).
    private String guidName(Address address) {
        if (address == null) return null;
        String known = guidAt.get(address);
        if (known != null) return known;
        byte[] bytes = new byte[16];
        try {
            if (currentProgram.getMemory().getBytes(address, bytes) != 16) return null;
        } catch (Exception error) {
            return null;
        }
        String key = hex(bytes, 0, 16);
        return key.equals(ZERO_GUID) || key.equals(ONES_GUID) ? null : guidNames.get(key);
    }

    /// (Un)InstallMultipleProtocolInterfaces is `(Handle, ...)`: every pair
    /// after the handle is a variable argument, and the decompiler often
    /// shows none of them. Declaring the first pair keeps the protocol a
    /// call installs in the C; later pairs stay variable.
    private void declareFirstPair(String field) {
        DataType table = type("EFI_BOOT_SERVICES");
        DataType guid = type("EFI_GUID");
        while (table instanceof TypeDef) table = ((TypeDef) table).getBaseDataType();
        if (!(table instanceof Structure) || guid == null) return;
        FunctionDefinition definition = null;
        for (DataTypeComponent component : ((Structure) table).getComponents()) {
            if (!field.equals(component.getFieldName())) continue;
            DataType type = component.getDataType();
            while (type instanceof TypeDef || type instanceof Pointer) {
                type = type instanceof TypeDef ? ((TypeDef) type).getBaseDataType()
                                               : ((Pointer) type).getDataType();
            }
            if (type instanceof FunctionDefinition) definition = (FunctionDefinition) type;
        }
        if (definition == null) return;
        ParameterDefinition[] current = definition.getArguments();
        if (current.length != 1) return;
        DataTypeManager manager = currentProgram.getDataTypeManager();
        definition.setArguments(new ParameterDefinition[] {
            current[0],
            new ParameterDefinitionImpl("Protocol", pointer(guid, 1), "the first protocol's GUID"),
            new ParameterDefinitionImpl("Interface", new PointerDataType(VoidDataType.dataType, manager),
                "the first protocol's interface"),
        });
        definition.setVarArgs(true);
    }

    // MARK: - Names

    /// Names a place, unless something better than Ghidra's default already
    /// names it. Returns whether the name is now there.
    private boolean label(Address address, String name, String reason) {
        try {
            Symbol primary = currentProgram.getSymbolTable().getPrimarySymbol(address);
            if (primary != null && primary.getSource() != SourceType.DEFAULT) {
                return primary.getName().equals(name);
            }
            Symbol symbol = currentProgram.getSymbolTable().createLabel(address, unique(name),
                SourceType.ANALYSIS);
            symbol.setPrimary();
            reasons.add(address, reason);
            return true;
        } catch (Exception error) {
            return false;
        }
    }

    /// Names a function Ghidra left as FUN_…; a name the module or a user
    /// already gave is kept.
    private boolean name(Function function, String name, String reason) {
        if (function == null || function.getSymbol().getSource() != SourceType.DEFAULT) return false;
        try {
            function.setName(unique(name), SourceType.ANALYSIS);
            reasons.add(function.getEntryPoint(), reason);
            named++;
            return true;
        } catch (Exception error) {
            return false;
        }
    }

    /// `name`, or `name_2`, `name_3`… when a global of that name exists.
    private String unique(String name) {
        String candidate = name;
        for (int n = 2; !currentProgram.getSymbolTable().getGlobalSymbols(candidate).isEmpty(); n++) {
            candidate = name + "_" + n;
        }
        return candidate;
    }

    /// gEfiPciIoProtocolGuid → PciIo: what EDK2 calls a pointer to it.
    static String interfaceName(String guid) {
        String base = guid;
        if (base.startsWith("g")) base = base.substring(1);
        if (base.endsWith("Guid")) base = base.substring(0, base.length() - 4);
        if (base.startsWith("Efi") && base.length() > 3 && Character.isUpperCase(base.charAt(3))) {
            base = base.substring(3);
        }
        for (String suffix : new String[] { "Protocol", "Ppi" }) {
            if (base.endsWith(suffix) && base.length() > suffix.length()) {
                base = base.substring(0, base.length() - suffix.length());
            }
        }
        return base;
    }

    /// gEfiPciIoProtocolGuid → EFI_PCI_IO_PROTOCOL: the struct MdePkg declares
    /// for it, when the archive has one by that name.
    private DataType interfaceType(String guid) {
        String base = guid;
        if (base.startsWith("g")) base = base.substring(1);
        if (base.endsWith("Guid")) base = base.substring(0, base.length() - 4);
        StringBuilder snake = new StringBuilder();
        for (int i = 0; i < base.length(); i++) {
            char c = base.charAt(i);
            if (i > 0 && Character.isUpperCase(c)
                    && (Character.isLowerCase(base.charAt(i - 1)) || Character.isDigit(base.charAt(i - 1)))) {
                snake.append('_');
            }
            snake.append(Character.toUpperCase(c));
        }
        String name = snake.toString();
        DataType type = type(name);
        if (type == null && !name.startsWith("EFI_")) type = type("EFI_" + name);
        return type;
    }

    // MARK: - The entry point and the parameters

    private void typeEntry() throws Exception {
        for (Address address : currentProgram.getSymbolTable().getExternalEntryPointIterator()) {
            Function function = getFunctionAt(address);
            if (function != null) {
                entry = function;
                break;
            }
        }
        // getFunction(String) is marked for removal in Ghidra 12.2; the
        // global functions by name are the same lookup.
        if (entry == null) {
            List<Function> named = getGlobalFunctions("entry");
            if (!named.isEmpty()) entry = named.get(0);
        }
        if (entry == null) return;
        DataType status = type("EFI_STATUS");
        Parameter first, second;
        if (pei) {
            DataType handle = type("EFI_PEI_FILE_HANDLE");
            DataType services = type("EFI_PEI_SERVICES");
            if (handle == null || services == null) return;
            first = new ParameterImpl("FileHandle", handle, currentProgram);
            second = new ParameterImpl("PeiServices", pointer(services, 2), currentProgram);
        } else {
            DataType handle = type("EFI_HANDLE");
            DataType table = type("EFI_SYSTEM_TABLE");
            if (handle == null || table == null) return;
            first = new ParameterImpl("ImageHandle", handle, currentProgram);
            second = new ParameterImpl("SystemTable", pointer(table, 1), currentProgram);
        }
        // EFIAPI: cdecl on IA32, the Microsoft x64 convention on X64. Ghidra
        // may have guessed __thiscall from an ECX use, which would put a
        // `this` in front of the two parameters.
        setEfiApi(entry);
        entry.replaceParameters(Function.FunctionUpdateType.DYNAMIC_STORAGE_FORMAL_PARAMS, true,
            SourceType.ANALYSIS, first, second);
        if (status != null) entry.setReturnType(status, SourceType.ANALYSIS);
        typedParameters += 2;
        name(entry, "_ModuleEntryPoint",
            "the image's entry point; EDK2 calls it _ModuleEntryPoint");
    }

    /// Firmware is C: no function has a `this`. Ghidra guesses __thiscall
    /// for a 32-bit function that happens to read ECX, and then every call
    /// to it passes a `this` and every caller grows `extraout_ECX` values.
    /// A convention Ghidra guessed is put back to cdecl, EFIAPI on IA32; one
    /// a user or the image's own symbols set is kept.
    private void dropThisCall() {
        if (currentProgram.getDefaultPointerSize() != 4) return;
        int dropped = 0;
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (!"__thiscall".equals(function.getCallingConventionName())) continue;
            if (function.getSignatureSource() == SourceType.USER_DEFINED
                    || function.getSignatureSource() == SourceType.IMPORTED) continue;
            try {
                function.setCallingConvention("__cdecl");
                dropped++;
            } catch (Exception unknown) {
                // No cdecl in this language; the guess stays.
            }
        }
        println("ApplyUefi: " + dropped + " __thiscall guesses set to __cdecl");
    }

    private void setEfiApi(Function function) {
        try {
            String convention = currentProgram.getDefaultPointerSize() == 4 ? "__cdecl"
                : currentProgram.getCompilerSpec().getDefaultCallingConvention().getName();
            function.setCallingConvention(convention);
        } catch (Exception unknown) {
            // The language has no such convention; Ghidra's stays.
        }
    }

    /// The variable an argument carries, through the casts and copies the
    /// decompiler puts between a typed parameter and a call: `(int *)PeiServices`.
    private static HighVariable carried(Varnode argument) {
        Varnode varnode = argument;
        for (int depth = 0; varnode != null && depth < 4; depth++) {
            HighVariable high = varnode.getHigh();
            if (high != null && isTracked(high)) return high;
            PcodeOp def = varnode.getDef();
            if (def == null || (def.getOpcode() != PcodeOp.CAST && def.getOpcode() != PcodeOp.COPY)) {
                return null;
            }
            varnode = def.getInput(0);
        }
        return null;
    }

    /// A value whose type follows the calls: a service table, or the image's
    /// own handle. Any EFI_HANDLE is not one — only the parameter the entry
    /// point's ImageHandle was handed down as.
    private static boolean isTracked(HighVariable high) {
        String key = key(high.getDataType());
        if (TRACKED.containsKey(key)) return true;
        return key.equals("EFI_HANDLE") && isImageHandle(high);
    }

    private static boolean isImageHandle(HighVariable high) {
        HighSymbol symbol = high.getSymbol();
        return symbol != null && symbol.isParameter() && "ImageHandle".equals(symbol.getName());
    }

    private HighFunction decompile(Function function) {
        if (function == null || function.isExternal() || function.isThunk()) return null;
        DecompileResults results = decompiler.decompileFunction(function, 60, monitor);
        return results != null && results.decompileCompleted() ? results.getHighFunction() : null;
    }

    /// A function called with SystemTable or PeiServices as an argument gets
    /// that parameter's type — and passes it on to what it calls in turn.
    private void propagateParameters() throws Exception {
        if (entry == null) return;
        Deque<Function> work = new ArrayDeque<>();
        Set<Function> queued = new HashSet<>();
        work.add(entry);
        queued.add(entry);
        while (!work.isEmpty() && !monitor.isCancelled()) {
            Function caller = work.poll();
            HighFunction high = decompile(caller);
            if (high == null) continue;
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALL) continue;
                Function callee = getFunctionAt(op.getInput(0).getAddress());
                if (callee == null || callee.isThunk() || callee.isExternal()) continue;
                for (int slot = 1; slot < op.getNumInputs(); slot++) {
                    HighVariable argument = carried(op.getInput(slot));
                    if (argument == null) continue;
                    if (giveParameter(callee, slot - 1, argument)) {
                        typedParameters++;
                        if (queued.add(callee)) work.add(callee);
                    }
                }
            }
        }
    }

    /// Gives `callee`'s parameter `index` the type and name of the argument,
    /// when the callee's own parameter has no type yet.
    private boolean giveParameter(Function callee, int index, HighVariable argument) throws Exception {
        if (callee.getParameterCount() <= index) {
            HighFunction high = decompile(callee);
            if (high == null) return false;
            HighFunctionDBUtil.commitParamsToDatabase(high, true,
                HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.ANALYSIS);
        }
        Parameter parameter = callee.getParameter(index);
        if (parameter == null || parameter.getSource() == SourceType.USER_DEFINED
                || parameter.getSource() == SourceType.IMPORTED) return false;
        DataType current = parameter.getDataType();
        DataType wanted = argument.getDataType();
        if (key(current).equals(key(wanted))) return false;
        if (!Undefined.isUndefined(current) && !(current instanceof Pointer
                && Undefined.isUndefined(((Pointer) current).getDataType()))
                && current.getLength() != wanted.getLength()) return false;
        parameter.setDataType(wanted, SourceType.ANALYSIS);
        HighSymbol symbol = argument.getSymbol();
        String name = symbol != null && symbol.isParameter() ? symbol.getName() : null;
        if (name != null && !name.startsWith("param_")) {
            try {
                parameter.setName(name, SourceType.ANALYSIS);
            } catch (Exception taken) {
                // Another parameter of the callee has that name.
            }
        }
        return true;
    }

    // MARK: - Globals

    /// A global written from SystemTable, BootServices, RuntimeServices, the
    /// image handle or the MM table is the one the EDK2 libraries keep.
    private void nameGlobals() throws Exception {
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            HighFunction high = decompile(function);
            if (high == null) continue;
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                Varnode value;
                Address target;
                int code = op.getOpcode();
                // A write is a COPY to the global, a STORE through its
                // address, or — when a call follows that may read it — an
                // INDIRECT whose first input is the value written rather than
                // the global's own earlier value.
                if ((code == PcodeOp.COPY || code == PcodeOp.INDIRECT) && op.getOutput() != null
                        && op.getOutput().isAddress()
                        && !(op.getInput(0).isAddress()
                             && op.getInput(0).getAddress().equals(op.getOutput().getAddress()))) {
                    value = op.getInput(0);
                    target = op.getOutput().getAddress();
                } else if (op.getOpcode() == PcodeOp.STORE) {
                    value = op.getInput(2);
                    target = constantAddress(op.getInput(1));
                } else {
                    continue;
                }
                if (target == null || !currentProgram.getMemory().contains(target)) continue;
                HighVariable carriedValue = carried(value);
                if (carriedValue == null) continue;
                DataType type = carriedValue.getDataType();
                String name = TRACKED.get(key(type));
                String reason = name == null ? null
                    : "written from a " + key(type) + " value in " + function.getName();
                if (name == null && !pei && key(type).equals("EFI_HANDLE")
                        && isImageHandle(carriedValue)) {
                    name = "gImageHandle";
                    reason = "written from the ImageHandle the entry point was given, in "
                        + function.getName();
                }
                if (name == null || type == null) continue;
                if (typeGlobal(target, type, name, reason)) typedGlobals++;
            }
        }
    }

    private boolean typeGlobal(Address address, DataType type, String name, String reason) {
        Symbol primary = currentProgram.getSymbolTable().getPrimarySymbol(address);
        if (primary != null && primary.getSource() != SourceType.DEFAULT) return false;
        if (!putData(address, type)) {
            // The place could not take the type; its name still helps.
            return label(address, name, reason);
        }
        return label(address, name, reason);
    }

    /// Puts `type` at `address`. Data Ghidra's own analysis left there — an
    /// undefined, a pointer, a value of the same size — gives way; anything
    /// else (a structure, a string, a user's type) is kept.
    private boolean putData(Address address, DataType type) {
        try {
            DataUtilities.createData(currentProgram, address, type, -1,
                DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
            return true;
        } catch (Exception conflict) {
            Data existing = currentProgram.getListing().getDataAt(address);
            if (existing == null) return false;
            DataType held = existing.getDataType();
            boolean analysis = held instanceof Pointer || Undefined.isUndefined(held)
                || existing.getLength() == type.getLength() && !(held instanceof Structure);
            if (!analysis || existing.getLength() > type.getLength()) return false;
            try {
                currentProgram.getListing().clearCodeUnits(address,
                    address.add(Math.max(existing.getLength(), type.getLength()) - 1), false);
                DataUtilities.createData(currentProgram, address, type, -1,
                    DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
                return true;
            } catch (Exception still) {
                return false;
            }
        }
    }

    /// The address a varnode is a constant pointer to: `#0x1234`, or the
    /// decompiler's `PTRSUB(#0, #0x1234)`, through copies and casts.
    private Address constantAddress(Varnode varnode) {
        for (int depth = 0; varnode != null && depth < 6; depth++) {
            if (varnode.isConstant()) return safeAddress(varnode.getOffset());
            PcodeOp def = varnode.getDef();
            if (def == null) return null;
            int code = def.getOpcode();
            if (code == PcodeOp.COPY || code == PcodeOp.CAST) {
                varnode = def.getInput(0);
            } else if (code == PcodeOp.PTRSUB && def.getInput(0).isConstant()
                    && def.getInput(0).getOffset() == 0 && def.getInput(1).isConstant()) {
                return safeAddress(def.getInput(1).getOffset());
            } else {
                return null;
            }
        }
        return null;
    }

    private Address safeAddress(long offset) {
        try {
            Address address = toAddr(offset);
            return currentProgram.getMemory().contains(address) ? address : null;
        } catch (Exception error) {
            return null;
        }
    }

    // MARK: - Service calls

    /// The field of a service table a call goes through: `LocateProtocol` for
    /// `(*gBS->LocateProtocol)(…)`, `LocatePpi` for `(*(*PeiServices)->LocatePpi)(…)`.
    private String serviceField(PcodeOp call) {
        Varnode target = call.getInput(0);
        for (int depth = 0; target != null && depth < 4; depth++) {
            PcodeOp def = target.getDef();
            if (def == null) return null;
            if (def.getOpcode() == PcodeOp.COPY || def.getOpcode() == PcodeOp.CAST) {
                target = def.getInput(0);
                continue;
            }
            if (def.getOpcode() != PcodeOp.LOAD) return null;
            PcodeOp field = def.getInput(1).getDef();
            if (field == null) return null;
            if (field.getOpcode() != PcodeOp.PTRSUB && field.getOpcode() != PcodeOp.INT_ADD) return null;
            Varnode base = field.getInput(0);
            Varnode offset = field.getInput(1);
            if (!offset.isConstant() || base.getHigh() == null) return null;
            DataType type = base.getHigh().getDataType();
            if (!(type instanceof Pointer)) return null;
            DataType table = ((Pointer) type).getDataType();
            while (table instanceof TypeDef) table = ((TypeDef) table).getBaseDataType();
            if (!(table instanceof Structure)) return null;
            DataTypeComponent component = ((Structure) table).getComponentAt((int) offset.getOffset());
            return component == null ? null : component.getFieldName();
        }
        return null;
    }

    private void followServiceCalls() throws Exception {
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            HighFunction high = decompile(function);
            if (high == null) continue;
            // An event created in this function, for a notify registered here.
            Function createdCallback = null;
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALLIND) continue;
                String field = serviceField(op);
                if (field == null) continue;
                switch (field) {
                    case "LocateProtocol":
                        consumed(high, op, 1, 3, "LocateProtocol");
                        break;
                    case "HandleProtocol":
                    case "OpenProtocol":
                        consumed(high, op, 2, 3, field);
                        break;
                    case "LocatePpi":
                        consumed(high, op, 2, 5, "LocatePpi");
                        break;
                    case "InstallProtocolInterface":
                        installed(op, 2, 4);
                        break;
                    case "InstallMultipleProtocolInterfaces":
                        for (int slot = 2; slot + 1 < op.getNumInputs(); slot += 2) installed(op, slot, slot + 1);
                        break;
                    case "InstallPpi":
                        descriptors(op, 2, false);
                        break;
                    case "NotifyPpi":
                        descriptors(op, 2, true);
                        break;
                    case "CreateEvent":
                        createdCallback = op.getNumInputs() > 3 ? functionAt(op.getInput(3)) : null;
                        break;
                    case "CreateEventEx":
                        if (op.getNumInputs() > 5) {
                            String group = guidName(constantAddress(op.getInput(5)));
                            Function callback = functionAt(op.getInput(3));
                            if (group != null && callback != null) {
                                name(callback, "On" + interfaceName(group),
                                    "CreateEventEx registers it for the " + group + " event group");
                            }
                        }
                        break;
                    case "RegisterProtocolNotify":
                        String guid = guidName(constantAddress(op.getInput(1)));
                        if (guid != null && createdCallback != null) {
                            name(createdCallback, "On" + interfaceName(guid) + "Installed",
                                "its event is the one RegisterProtocolNotify ties to " + guid);
                        }
                        break;
                    default:
                        break;
                }
            }
        }
    }

    /// The function a constant code pointer names. A callback only ever
    /// reached through a pointer may not be a function yet; it is made one
    /// when the address is executable code.
    private Function functionAt(Varnode varnode) {
        Address address = constantAddress(varnode);
        return address == null ? null : functionAtAddress(address);
    }

    private Function functionAtAddress(Address address) {
        Function function = getFunctionAt(address);
        if (function != null) return function;
        MemoryBlock block = currentProgram.getMemory().getBlock(address);
        if (block == null || !block.isExecute()) return null;
        try {
            if (currentProgram.getListing().getInstructionAt(address) == null) disassemble(address);
            return createFunction(address, null);
        } catch (Exception error) {
            return null;
        }
    }

    /// A protocol or PPI the module looks up: the out argument is typed as a
    /// pointer to it and named after it — a global gPciIo, a local PciIo.
    private void consumed(HighFunction high, PcodeOp call, int guidSlot, int outSlot, String service) {
        if (call.getNumInputs() <= outSlot) return;
        String guid = serviceGuid(call, guidSlot, service);
        if (guid == null) return;
        DataType iface = interfaceType(guid);
        DataType pointerType = iface == null ? null : pointer(iface, 1);
        String base = interfaceName(guid);
        String reason = service + " fills it with the " + guid + " interface";
        Address global = constantAddress(call.getInput(outSlot));
        if (global != null) {
            if (pointerType != null ? typeGlobal(global, pointerType, "g" + base, reason)
                                    : label(global, "g" + base, reason)) {
                typedGlobals++;
            }
            return;
        }
        PcodeOp reference = call.getInput(outSlot).getDef();
        if (reference == null || reference.getOpcode() != PcodeOp.PTRSUB) return;
        Address stack = HighFunctionDBUtil.getSpacebaseReferenceAddress(
            currentProgram.getAddressFactory(), reference);
        if (stack == null || !stack.isStackAddress()) return;
        HighSymbol local = high.getLocalSymbolMap().findLocal(stack, null);
        if (local == null || local.isNameLocked()) return;
        try {
            HighFunctionDBUtil.updateDBVariable(local, base,
                pointerType != null ? pointerType : local.getDataType(), SourceType.ANALYSIS);
            typedLocals++;
        } catch (Exception taken) {
            // The name is taken in this function, or the storage moved.
        }
    }

    /// The GUID a service call is handed. One the catalogue does not know is
    /// still a GUID — the service says so — and is typed and called
    /// gUnknownGuid_<Data1>, so its uses are one name and the panel says plainly
    /// that nobody has named it. Returns the catalogue's name, or null.
    private String serviceGuid(PcodeOp call, int slot, String service) {
        Address address = constantAddress(call.getInput(slot));
        String name = guidName(address);
        if (name != null || address == null) return name;
        byte[] bytes = new byte[16];
        try {
            if (currentProgram.getMemory().getBytes(address, bytes) != 16) return null;
        } catch (Exception error) {
            return null;
        }
        String key = hex(bytes, 0, 16);
        if (key.equals(ZERO_GUID) || key.equals(ONES_GUID)) return null;
        DataType guid = type("EFI_GUID");
        if (guid == null) return null;
        String data1 = String.format("%08X", (bytes[0] & 0xFFL) | (bytes[1] & 0xFFL) << 8
            | (bytes[2] & 0xFFL) << 16 | (bytes[3] & 0xFFL) << 24);
        if (typeGlobal(address, guid, "gUnknownGuid_" + data1,
                service + " is handed this GUID; the catalogue has no name for it")) {
            guidAt.put(address, "gUnknownGuid_" + data1);
        }
        return null;
    }

    /// An interface the module installs: typed and named mPciIo, for an
    /// interface in the module's own data.
    private void installed(PcodeOp call, int guidSlot, int interfaceSlot) {
        if (call.getNumInputs() <= interfaceSlot) return;
        String guid = serviceGuid(call, guidSlot, "InstallProtocolInterface");
        Address iface = constantAddress(call.getInput(interfaceSlot));
        if (guid == null || iface == null) return;
        DataType type = interfaceType(guid);
        String reason = "installed as the " + guid + " interface";
        if (type != null ? typeGlobal(iface, type, "m" + interfaceName(guid), reason)
                         : label(iface, "m" + interfaceName(guid), reason)) {
            typedGlobals++;
        }
    }

    /// An InstallPpi or NotifyPpi list: { Flags, Guid*, Ppi* or Notify } until
    /// the flag that ends the list. The descriptors are typed, the PPI named,
    /// the notify function named after what it waits for.
    private void descriptors(PcodeOp call, int listSlot, boolean notify) throws Exception {
        if (call.getNumInputs() <= listSlot) return;
        Address list = constantAddress(call.getInput(listSlot));
        if (list == null) return;
        int pointerSize = currentProgram.getDefaultPointerSize();
        DataType descriptor = type(notify ? "EFI_PEI_NOTIFY_DESCRIPTOR" : "EFI_PEI_PPI_DESCRIPTOR");
        Memory memory = currentProgram.getMemory();
        Address at = list;
        for (int index = 0; index < 32; index++) {
            long flags = pointerSize == 8 ? memory.getLong(at) : memory.getInt(at) & 0xFFFFFFFFL;
            Address guidPointer = pointerAt(at.add(pointerSize));
            Address second = pointerAt(at.add(2L * pointerSize));
            String guid = guidName(guidPointer);
            if (descriptor != null) putData(at, descriptor);
            if (guid != null && second != null) {
                if (notify) {
                    name(functionAtAddress(second), "On" + interfaceName(guid) + "Installed",
                        "NotifyPpi calls it when " + guid + " is installed");
                } else {
                    DataType type = interfaceType(guid);
                    String reason = "InstallPpi installs it as " + guid;
                    if (type != null ? typeGlobal(second, type, "m" + interfaceName(guid), reason)
                                     : label(second, "m" + interfaceName(guid), reason)) {
                        typedGlobals++;
                    }
                }
            }
            // EFI_PEI_PPI_DESCRIPTOR_TERMINATE_LIST
            if ((flags & 0x80000000L) != 0 || guidPointer == null) break;
            at = at.add(3L * pointerSize);
        }
    }

    private Address pointerAt(Address address) {
        try {
            long value = currentProgram.getDefaultPointerSize() == 8
                ? currentProgram.getMemory().getLong(address)
                : currentProgram.getMemory().getInt(address) & 0xFFFFFFFFL;
            return safeAddress(value);
        } catch (Exception error) {
            return null;
        }
    }

    // MARK: - DEBUG strings

    /// DEBUG ((DEBUG_INFO, "%a: …", __FUNCTION__)) puts the function's own
    /// name in its data. A function whose calls pass a "%a" format and one
    /// identifier-like string is named by it — unless another function claims
    /// the same identifier, which is then not evidence of either.
    private void nameFromDebugStrings() throws Exception {
        Map<String, List<Function>> claims = new HashMap<>();
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            if (function.getSymbol().getSource() != SourceType.DEFAULT) continue;
            HighFunction high = decompile(function);
            if (high == null) continue;
            Set<String> found = new HashSet<>();
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALL && op.getOpcode() != PcodeOp.CALLIND) continue;
                boolean format = false;
                List<String> identifiers = new ArrayList<>();
                for (int slot = 1; slot < op.getNumInputs(); slot++) {
                    String text = ascii(constantAddress(op.getInput(slot)));
                    if (text == null) continue;
                    if (text.contains("%a")) format = true;
                    else if (IDENTIFIER.matcher(text).matches()) identifiers.add(text);
                }
                if (format && identifiers.size() == 1) found.add(identifiers.get(0));
            }
            if (found.size() == 1) {
                claims.computeIfAbsent(found.iterator().next(), key -> new ArrayList<>()).add(function);
            }
        }
        for (Map.Entry<String, List<Function>> claim : claims.entrySet()) {
            if (claim.getValue().size() != 1) continue;
            name(claim.getValue().get(0), claim.getKey(),
                "its DEBUG message passes \"" + claim.getKey() + "\" for a %a — EDK2's __FUNCTION__");
        }
    }

    /// The NUL-terminated ASCII at an address, or null when it is not text.
    private String ascii(Address address) {
        if (address == null) return null;
        StringBuilder text = new StringBuilder();
        try {
            for (int i = 0; i < 256; i++) {
                int c = currentProgram.getMemory().getByte(address.add(i)) & 0xFF;
                if (c == 0) return text.length() > 0 ? text.toString() : null;
                if (c < 0x20 && c != '\n' && c != '\r' && c != '\t' || c >= 0x7F) return null;
                text.append((char) c);
            }
        } catch (Exception error) {
            return null;
        }
        return null;
    }
}
