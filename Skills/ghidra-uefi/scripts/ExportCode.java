// Export one analyzed program as the rich, read-later code artifact.
//
//   analyzeHeadless ... -postScript ExportCode.java out.json
//
// The artifact is what the Code panel and an agent read after Ghidra is gone:
// every function with its decompiled C, every instruction with its bytes and
// references, the program's blocks, its strings, and the writes to the POST
// port. The JSON is intentionally explicit rather than compact; a module of a
// few kilobytes stays small, and a reader can see what was written.
// @category ByteRipper

import java.io.File;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.decompiler.ClangFuncNameToken;
import ghidra.app.decompiler.ClangLine;
import ghidra.app.decompiler.ClangToken;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.decompiler.PrettyPrinter;
import ghidra.app.script.GhidraScript;
import ghidra.framework.Application;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.data.DataType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.pcode.PcodeOp;
import ghidra.program.model.pcode.Varnode;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.SymbolType;
import ghidra.program.model.util.StringPropertyMap;
import ghidra.program.model.scalar.Scalar;

public class ExportCode extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("usage: ExportCode.java <out.json>");
            return;
        }
        File out = new File(args[0]);

        Listing listing = currentProgram.getListing();
        StringBuilder json = new StringBuilder(1 << 22);
        json.append("{\n");
        json.append("  \"script_version\": 4,\n");
        json.append("  \"ghidra\": ").append(quote(Application.getApplicationVersion())).append(",\n");
        json.append("  \"program\": {\n");
        json.append("    \"name\": ").append(quote(currentProgram.getName())).append(",\n");
        json.append("    \"language\": ").append(quote(currentProgram.getLanguageID().toString())).append(",\n");
        json.append("    \"image_base\": ").append(quote(hex(currentProgram.getImageBase()))).append(",\n");
        json.append("    \"sha256\": ").append(quote(currentProgram.getExecutableSHA256())).append("\n");
        json.append("  },\n");

        // Blocks: the address ranges the program has, and whether they are code.
        json.append("  \"blocks\": [");
        MemoryBlock[] blocks = currentProgram.getMemory().getBlocks();
        for (int i = 0; i < blocks.length; i++) {
            MemoryBlock block = blocks[i];
            if (i > 0) json.append(", ");
            json.append("{\"name\": ").append(quote(block.getName()))
                .append(", \"start\": ").append(quote(hex(block.getStart())))
                .append(", \"end\": ").append(quote(hex(block.getEnd())))
                .append(", \"executable\": ").append(block.isExecute())
                .append(", \"initialized\": ").append(block.isInitialized())
                .append("}");
        }
        json.append("],\n");

        // Strings worth naming: every defined string, whatever Ghidra's type
        // for it — `string`, `TerminatedCString`, `unicode`,
        // `TerminatedUnicode` — and then the UTF-16 runs Ghidra left as bytes.
        // UEFI names its variables and its menus in UTF-16 (`L"BootOrder"`);
        // a list without them misses what a repair is usually looking for.
        List<long[]> stringOrder = new ArrayList<>();
        List<String> stringEntries = new ArrayList<>();
        AddressSet definedStrings = new AddressSet();
        DataIterator data = listing.getDefinedData(true);
        while (data.hasNext() && !monitor.isCancelled()) {
            Data item = data.next();
            if (!item.hasStringValue()) continue;
            DataType type = item.getDataType();
            Object value;
            try {
                value = item.getValue();
            } catch (Exception error) {
                continue;
            }
            if (value == null) continue;
            definedStrings.add(item.getMinAddress(), item.getMaxAddress());
            stringOrder.add(new long[] { item.getAddress().getOffset(), stringEntries.size() });
            stringEntries.add("{\"address\": " + quote(hex(item.getAddress()))
                + ", \"type\": " + quote(type == null ? "string" : type.getName())
                + ", \"value\": " + quote(value.toString()) + "}");
        }
        for (MemoryBlock block : blocks) {
            if (monitor.isCancelled()) break;
            if (!block.isInitialized() || block.getSize() > (64L << 20)) continue;
            byte[] bytes = new byte[(int) block.getSize()];
            try {
                block.getBytes(block.getStart(), bytes);
            } catch (Exception error) {
                continue;
            }
            int index = 0;
            while (index + 1 < bytes.length) {
                int length = 0;
                while (index + 2 * length + 1 < bytes.length
                        && bytes[index + 2 * length + 1] == 0
                        && isText(bytes[index + 2 * length])) {
                    length++;
                }
                boolean terminated = index + 2 * length + 1 < bytes.length
                    && bytes[index + 2 * length] == 0 && bytes[index + 2 * length + 1] == 0;
                if (length >= 4 && terminated) {
                    Address start = block.getStart().add(index);
                    if (!definedStrings.contains(start)
                            && listing.getInstructionContaining(start) == null) {
                        StringBuilder text = new StringBuilder(length);
                        for (int at = 0; at < length; at++) text.append((char) bytes[index + 2 * at]);
                        stringOrder.add(new long[] { start.getOffset(), stringEntries.size() });
                        stringEntries.add("{\"address\": " + quote(hex(start))
                            + ", \"type\": \"unicode\", \"value\": " + quote(text.toString())
                            + ", \"source\": \"scan\"}");
                    }
                    index += 2 * (length + 1);
                } else {
                    index += 2;
                }
            }
        }
        stringOrder.sort((left, right) -> Long.compare(left[0], right[0]));
        List<String> strings = new ArrayList<>();
        for (long[] entry : stringOrder) strings.add(stringEntries.get((int) entry[1]));
        json.append("  \"strings\": [").append(String.join(", ", strings)).append("],\n");

        StringPropertyMap reasons =
            currentProgram.getUsrPropertyManager().getStringPropertyMap("ByteRipper.nameReason");
        // Named data: the GUIDs, service tables and interfaces the UEFI pass
        // named, and whatever the image's own symbols named.
        List<String> symbols = new ArrayList<>();
        SymbolIterator named = currentProgram.getSymbolTable().getPrimarySymbolIterator(true);
        while (named.hasNext() && !monitor.isCancelled()) {
            Symbol symbol = named.next();
            if (symbol.getSymbolType() != SymbolType.LABEL || symbol.getSource() == SourceType.DEFAULT
                    || !symbol.getAddress().isMemoryAddress()) continue;
            Data item = listing.getDataAt(symbol.getAddress());
            String why = reasons == null ? null : reasons.getString(symbol.getAddress());
            symbols.add("{\"address\": " + quote(hex(symbol.getAddress()))
                + ", \"name\": " + quote(symbol.getName())
                + ", \"type\": " + quote(item == null ? null : item.getDataType().getDisplayName())
                + ", \"source\": " + quote(symbol.getSource().name())
                + (why == null ? "" : ", \"reason\": " + quote(why)) + "}");
        }
        json.append("  \"symbols\": [").append(String.join(", ", symbols)).append("],\n");

        // Functions, in address order, with their instructions and decompiled C.
        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.openProgram(currentProgram);

        List<Function> functions = new ArrayList<>();
        FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
        while (iterator.hasNext() && !monitor.isCancelled()) functions.add(iterator.next());

        List<String> postCodes = new ArrayList<>();
        List<String> statusCodeCalls = new ArrayList<>();
        // `[reg + 0x58]` is ReportStatusCode in the 32-bit PEI services
        // table. In a 64-bit image the same slot is Boot Services' SetTimer or
        // Runtime Services' SetVariable, so no candidate is named there.
        boolean thirtyTwoBit = currentProgram.getLanguage().getLanguageDescription().getSize() == 32;
        json.append("  \"functions\": [\n");
        for (int index = 0; index < functions.size(); index++) {
            Function function = functions.get(index);
            if (monitor.isCancelled()) break;
            json.append("    {\n");
            json.append("      \"entry\": ").append(quote(hex(function.getEntryPoint()))).append(",\n");
            json.append("      \"name\": ").append(quote(function.getName())).append(",\n");
            json.append("      \"size\": ").append(function.getBody().getNumAddresses()).append(",\n");
            json.append("      \"external\": ").append(function.isExternal()).append(",\n");
            json.append("      \"thunk\": ").append(function.isThunk()).append(",\n");
            json.append("      \"signature\": ").append(quote(function.getPrototypeString(false, false))).append(",\n");

            // Ghidra answers with sets; sorted by entry, the same program
            // always exports the same bytes, which is what lets a publish of
            // an unchanged program be recognised as one.
            List<String> callers = entries(function.getCallingFunctions(monitor));
            List<String> callees = entries(function.getCalledFunctions(monitor));
            json.append("      \"callers\": [").append(String.join(", ", callers)).append("],\n");
            json.append("      \"callees\": [").append(String.join(", ", callees)).append("],\n");

            // Where the name came from: Ghidra's FUN_ placeholder (DEFAULT),
            // the UEFI pass (ANALYSIS, with its reason), the image's own
            // symbols (IMPORTED) or a user.
            json.append("      \"name_source\": ")
                .append(quote(function.getSymbol().getSource().name())).append(",\n");
            String reason = reasons == null ? null : reasons.getString(function.getEntryPoint());
            if (reason != null) {
                json.append("      \"name_reason\": ").append(quote(reason)).append(",\n");
            }

            if (!function.isExternal() && !function.isThunk()) {
                DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
                if (results != null && results.decompileCompleted()
                        && results.getCCodeMarkup() != null) {
                    appendC(json, function, results);
                }
            }

            List<String> instructions = new ArrayList<>();
            List<String> recent = new ArrayList<>();
            InstructionIterator code = listing.getInstructions(function.getBody(), true);
            while (code.hasNext() && !monitor.isCancelled()) {
                Instruction instruction = code.next();
                String bytes = "";
                try {
                    bytes = hexBytes(instruction.getBytes());
                } catch (Exception ignored) {
                    // A partly mapped instruction still has text worth keeping.
                }
                List<String> references = new ArrayList<>();
                Reference[] refs = instruction.getReferencesFrom();
                for (Reference reference : refs) {
                    if (reference.getReferenceType().isFallthrough()) continue;
                    references.add("{\"to\": " + quote(hex(reference.getToAddress()))
                        + ", \"type\": " + quote(reference.getReferenceType().toString()) + "}");
                }
                String text = instruction.toString();
                // A call through a table entry at +0x58 is the PEI
                // ReportStatusCode call in a 32-bit PEI services table; the
                // pushes just before it carry Type and Value. A candidate,
                // because another table could use the same displacement.
                if (thirtyTwoBit && instruction.getFlowType().isCall() && text.matches(".*\\[\\s*\\w+\\s*\\+\\s*0x58\\s*\\].*")) {
                    List<String> context = new ArrayList<>(recent);
                    statusCodeCalls.add("{\"address\": " + quote(hex(instruction.getAddress()))
                        + ", \"function\": " + quote(hex(function.getEntryPoint()))
                        + ", \"text\": " + quote(text)
                        + ", \"context\": ["
                        + String.join(", ", context.stream().map(ExportCode::quote).toList())
                        + "]}");
                }
                instructions.add("{\"address\": " + quote(hex(instruction.getAddress()))
                    + ", \"bytes\": " + quote(bytes)
                    + ", \"mnemonic\": " + quote(instruction.getMnemonicString())
                    + ", \"text\": " + quote(text)
                    + ", \"flow\": " + quote(instruction.getFlowType().toString())
                    + ", \"references\": [" + String.join(", ", references) + "]}");

                // A write to the POST port is what a board's POST card shows.
                if ("OUT".equalsIgnoreCase(instruction.getMnemonicString())) {
                    String port = "";
                    Object[] operands = instruction.getOpObjects(0);
                    if (operands.length > 0 && operands[0] instanceof Scalar) {
                        port = hex(((Scalar) operands[0]).getUnsignedValue());
                    } else if (operands.length > 0) {
                        port = operands[0].toString();
                    }
                    postCodes.add("{\"address\": " + quote(hex(instruction.getAddress()))
                        + ", \"function\": " + quote(hex(function.getEntryPoint()))
                        + ", \"port\": " + quote(port)
                        + ", \"text\": " + quote(text) + "}");
                }
                recent.add(text);
                if (recent.size() > 8) recent.remove(0);
            }
            json.append("      \"instructions\": [\n        ")
                .append(String.join(",\n        ", instructions)).append("\n      ]\n");
            json.append("    }");
            if (index + 1 < functions.size()) json.append(",");
            json.append("\n");
        }
        json.append("  ],\n");
        json.append("  \"post_codes\": [").append(String.join(", ", postCodes)).append("],\n");
        json.append("  \"status_code_calls\": [")
            .append(String.join(", ", statusCodeCalls)).append("]\n");
        json.append("}\n");

        try (Writer writer = Files.newBufferedWriter(out.toPath(), StandardCharsets.UTF_8)) {
            writer.write(json.toString());
        }
        decompiler.dispose();
        println("wrote " + functions.size() + " functions to " + out);
    }

    // The decompiled C, written from the decompiler's tokens so that every
    // token's place in the text is known, and the spans a reader colours and
    // follows: a called function with its entry, a global with its address,
    // a type, a parameter, a local, a constant, a keyword, a comment. Offsets
    // are UTF-16 code units into `c`, the units a Swift or Java string counts.
    private void appendC(StringBuilder json, Function function, DecompileResults results) {
        PrettyPrinter printer = new PrettyPrinter(function, results.getCCodeMarkup(), null);
        HighFunction high = results.getHighFunction();
        StringBuilder text = new StringBuilder();
        List<String> spans = new ArrayList<>();
        for (ClangLine line : printer.getLines()) {
            text.append(line.getIndentString());
            for (ClangToken token : line.getAllTokens()) {
                String piece = token.getText();
                int start = text.length();
                text.append(piece);
                if (piece.isEmpty() || piece.isBlank()) continue;
                String kind = null;
                String target = null;
                switch (token.getSyntaxType()) {
                    case ClangToken.KEYWORD_COLOR: kind = "keyword"; break;
                    case ClangToken.COMMENT_COLOR: kind = "comment"; break;
                    case ClangToken.TYPE_COLOR: kind = "type"; break;
                    case ClangToken.CONST_COLOR: kind = "constant"; break;
                    case ClangToken.PARAMETER_COLOR: kind = "parameter"; break;
                    case ClangToken.VARIABLE_COLOR: kind = "local"; break;
                    case ClangToken.FUNCTION_COLOR:
                        kind = "function";
                        target = calledEntry(token);
                        break;
                    case ClangToken.GLOBAL_COLOR:
                        kind = "global";
                        target = globalAddress(token, high);
                        break;
                    default: break;
                }
                if (kind == null) continue;
                spans.add("[" + start + ", " + piece.length() + ", " + quote(kind)
                    + (target == null ? "" : ", " + quote(target)) + "]");
            }
            text.append('\n');
        }
        json.append("      \"c\": ").append(quote(text.toString())).append(",\n");
        json.append("      \"c_spans\": [").append(String.join(", ", spans)).append("],\n");
    }

    // The entry a function-name token calls, or names: the CALL's target, or
    // the function of that name.
    private String calledEntry(ClangToken token) {
        PcodeOp op = token.getPcodeOp();
        if (op != null && op.getOpcode() == PcodeOp.CALL) {
            return hex(op.getInput(0).getAddress());
        }
        if (token instanceof ClangFuncNameToken) {
            List<Function> functions = getGlobalFunctions(token.getText());
            if (functions.size() == 1) return hex(functions.get(0).getEntryPoint());
        }
        return null;
    }

    // The address of a global a token names.
    private String globalAddress(ClangToken token, HighFunction high) {
        try {
            HighSymbol symbol = token.getHighSymbol(high);
            if (symbol != null && symbol.isGlobal() && symbol.getStorage() != null) {
                Address address = symbol.getStorage().getMinAddress();
                if (address != null && address.isMemoryAddress()) return hex(address);
            }
        } catch (Exception ignored) {
            // A token whose symbol cannot be read has no target.
        }
        Varnode varnode = token.getVarnode();
        if (varnode != null && varnode.isAddress() && varnode.getAddress().isMemoryAddress()) {
            return hex(varnode.getAddress());
        }
        return null;
    }

    private static List<String> entries(java.util.Set<Function> functions) {
        List<Address> addresses = new ArrayList<>();
        for (Function function : functions) addresses.add(function.getEntryPoint());
        java.util.Collections.sort(addresses);
        List<String> quoted = new ArrayList<>();
        for (Address address : addresses) quoted.add(quote(hex(address)));
        return quoted;
    }

    private static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }

    private static String hex(long value) {
        return String.format("0x%X", value);
    }

    // A UTF-16 code unit's low byte that reads as text: printable ASCII, a
    // tab or a line break.
    private static boolean isText(byte value) {
        int c = value & 0xFF;
        return (c >= 0x20 && c < 0x7F) || c == '\t' || c == '\n' || c == '\r';
    }

    private static String hexBytes(byte[] bytes) {
        StringBuilder builder = new StringBuilder();
        for (byte value : bytes) {
            if (builder.length() > 0) builder.append(' ');
            builder.append(String.format("%02X", value & 0xFF));
        }
        return builder.toString();
    }

    private static String quote(String value) {
        if (value == null) return "null";
        StringBuilder builder = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"': builder.append("\\\""); break;
                case '\\': builder.append("\\\\"); break;
                case '\n': builder.append("\\n"); break;
                case '\r': builder.append("\\r"); break;
                case '\t': builder.append("\\t"); break;
                case '\b': builder.append("\\b"); break;
                case '\f': builder.append("\\f"); break;
                default:
                    if (c < 0x20) builder.append(String.format("\\u%04x", (int) c));
                    else builder.append(c);
            }
        }
        return builder.append("\"").toString();
    }
}
