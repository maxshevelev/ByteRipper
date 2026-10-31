// The Ghidra owner of one module (Design/GHIDRA_SHARED_PLAN.md §6): a
// long-lived headless Ghidra that holds one program of a kept project and
// serves the bridge (§7) on a loopback port.
//
// The reads; the writes of a review (phase 2a) — function and variable
// names with who made them and why, signatures, comments, data, types — each
// in a transaction of its own and only under the write lease; and publish,
// which saves the program if it changed, runs ExportCode on it in this
// process, harvests the review document (Harvest.java) and returns the
// artifact. The client stores both. Nothing here writes to the store, and
// nothing here runs a script a client names.
//
// How it is built and run is `GhidraHost`'s business: javac
// against every jar of the Ghidra install, then
//
//   java -cp <ghidra jars>:owner.jar Owner --project-dir D --project-name N
//        --program P --module SHA --project-id UUID [--types ARCHIVE.gdt]
//        [--review-types DIR] [--port 0] [--idle SECONDS]
//
// --review-types names the folder of the archives of types reviews define
// (`review-types-Ia32.gdt`, `review-types-X64.gdt`, §6.5): the owner reads a
// copy taken when it starts, and merges its own review's types in at publish.
//
// It prints `OWNER READY <port>` once it serves. The plain classpath and the
// DomainFile open are the two findings of phase 0 (plan §3): a class on the
// classpath of ghidra.Ghidra's own class loader cannot see Ghidra, and
// GhidraProject.openProgram keeps a standing transaction that one failed
// change turns into a lost session.

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import ghidra.GhidraApplicationLayout;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.cmd.function.ApplyFunctionSignatureCmd;
import ghidra.app.script.GhidraState;
import ghidra.app.util.cparser.C.CParser;
import ghidra.app.util.cparser.C.CParserUtils;
import ghidra.app.script.ScriptControls;
import ghidra.base.project.GhidraProject;
import ghidra.framework.Application;
import ghidra.framework.HeadlessGhidraApplicationConfiguration;
import ghidra.framework.model.DomainFile;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeConflictHandler;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.FileDataTypeManager;
import ghidra.program.model.data.FunctionDefinitionDataType;
import ghidra.program.model.listing.CodeUnit;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Parameter;
import ghidra.program.model.listing.Program;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighFunctionDBUtil;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.util.StringPropertyMap;
import ghidra.util.data.DataTypeParser;
import ghidra.util.task.TaskMonitor;

import java.io.File;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Iterator;
import java.util.UUID;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class Owner {
    static final int PROTOCOL = 1;
    /**
     * The jar this owner runs from, as its modification time in seconds: a
     * host compares it with the jar it would start now, and replaces an
     * owner that outlived a rebuild — a server restarted on new sources
     * while the owner ran on.
     */
    static final long BUILD = build();

    private static long build() {
        try {
            File jar = new File(Owner.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            return jar.isFile() ? jar.lastModified() / 1000 : 0;
        } catch (Exception error) {
            return 0;
        }
    }

    private final Map<String, String> options;
    private GhidraProject project;
    private Program program;
    private DecompInterface decompiler;
    // The EDK2 archive the program was typed with, read-only: a type a
    // review names that the program does not hold yet comes from here.
    private FileDataTypeManager archive;
    // The types other reviews defined, as they were when this owner started:
    // a copy, so no owner ever holds the shared archive open (§6.5).
    private File reviewTypes;
    private File reviewTypesCopy;
    private FileDataTypeManager reviewArchive;
    private final Map<Address, DecompileResults> decompiled = new HashMap<>();
    private long decompiledAt = -1;
    private volatile long lastRequest = System.currentTimeMillis();
    // The write lease (§7.3): one holder at a time, renewed by every write.
    private String leaseToken;
    private String leaseHolder;
    private long leaseExpires;
    private long leaseTtl;
    // The review document of the last publish, for GET /v1/review.
    private Harvest.Document published;
    private final Gson gson = new GsonBuilder().disableHtmlEscaping().setPrettyPrinting().create();

    Owner(Map<String, String> options) {
        this.options = options;
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> options = new HashMap<>();
        for (int i = 0; i + 1 < args.length; i += 2) {
            if (!args[i].startsWith("--")) throw new IllegalArgumentException("unexpected " + args[i]);
            options.put(args[i].substring(2), args[i + 1]);
        }
        for (String required : new String[] {"project-dir", "project-name", "program", "module", "project-id"}) {
            if (!options.containsKey(required)) throw new IllegalArgumentException("--" + required + " is required");
        }
        new Owner(options).run();
    }

    private void run() throws Exception {
        Application.initializeApplication(new GhidraApplicationLayout(),
                                          new HeadlessGhidraApplicationConfiguration());
        project = GhidraProject.openProject(options.get("project-dir"), options.get("project-name"));
        DomainFile file = project.getProject().getProjectData().getFile("/" + options.get("program"));
        if (file == null) throw new IllegalStateException("no program " + options.get("program") + " in the project");
        program = (Program) file.getDomainObject(this, true, false, TaskMonitor.DUMMY);
        decompiler = new DecompInterface();
        decompiler.openProgram(program);
        if (options.containsKey("types")) {
            archive = FileDataTypeManager.openFileArchive(new File(options.get("types")), false);
        }
        if (options.containsKey("review-types")) {
            String bits = program.getDefaultPointerSize() == 8 ? "X64" : "Ia32";
            reviewTypes = new File(options.get("review-types"), "review-types-" + bits + ".gdt");
            if (reviewTypes.isFile()) {
                reviewTypesCopy = File.createTempFile("review-types-", ".gdt");
                try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
                    Files.copy(reviewTypes.toPath(), reviewTypesCopy.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
                reviewArchive = FileDataTypeManager.openFileArchive(reviewTypesCopy, false);
            }
        }
        // What the program held before anyone reviewed it — the loader's
        // comments, ApplyUefi's types — so a harvest holds only the review.
        int transaction = program.startTransaction("baseline");
        boolean recorded = false;
        try {
            recorded = Harvest.recordBaseline(program);
        } finally {
            program.endTransaction(transaction, recorded);
        }
        if (recorded) program.save("baseline", TaskMonitor.DUMMY);

        int port = Integer.parseInt(options.getOrDefault("port", "0"));
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        // One thread: every call sees the program between two changes, never
        // in the middle of one.
        server.setExecutor(Executors.newSingleThreadExecutor());
        server.createContext("/", this::handle);
        server.start();
        Runtime.getRuntime().addShutdownHook(new Thread(this::close));
        long idle = Long.parseLong(options.getOrDefault("idle", "0"));
        if (idle > 0) {
            Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(() -> {
                if (System.currentTimeMillis() - lastRequest > idle * 1000) {
                    System.out.println("OWNER IDLE");
                    System.exit(0);
                }
            }, idle, Math.max(1, idle / 4), TimeUnit.SECONDS);
        }
        // An expired lease saves what its holder changed; it does not publish:
        // there is no client to hand an artifact to (§5.4). Run on the server's
        // own thread, so it never lands in the middle of a change.
        Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(() -> {
            server.getExecutor().execute(this::expireLease);
        }, 5, 5, TimeUnit.SECONDS);
        System.out.println("OWNER READY " + server.getAddress().getPort());
        System.out.flush();
    }

    /** Save what changed and let the program go: on stop, idle and a signal. */
    private synchronized void close() {
        try {
            if (program == null) return;
            if (program.isChanged()) program.save("owner", TaskMonitor.DUMMY);
            if (decompiler != null) decompiler.dispose();
            if (archive != null) archive.close();
            if (reviewArchive != null) reviewArchive.close();
            if (reviewTypesCopy != null) reviewTypesCopy.delete();
            program.release(this);
            program = null;
            project.close();
        } catch (Exception error) {
            System.err.println("OWNER close: " + error);
        }
    }

    // MARK: - Requests

    private static final class Failure extends Exception {
        final int status;
        Failure(int status, String message) { super(message); this.status = status; }
    }

    private void handle(HttpExchange exchange) {
        lastRequest = System.currentTimeMillis();
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();
        Map<String, String> query = query(exchange.getRequestURI().getRawQuery());
        try {
            if (method.equals("GET")) {
                if (path.equals("/v1/hello")) { json(exchange, 200, hello()); return; }
                if (path.equals("/v1/functions")) { json(exchange, 200, functions(query)); return; }
                if (path.startsWith("/v1/function/")) { json(exchange, 200, function(path.substring(13), query)); return; }
                if (path.startsWith("/v1/disassembly/")) { json(exchange, 200, disassembly(path.substring(16), query)); return; }
                if (path.equals("/v1/xrefs")) { json(exchange, 200, xrefs(query)); return; }
                if (path.equals("/v1/data")) { json(exchange, 200, data(query, false)); return; }
                if (path.equals("/v1/strings")) { json(exchange, 200, data(query, true)); return; }
                if (path.equals("/v1/review")) { review(exchange); return; }
                if (path.equals("/v1/review/description")) { publishedDescription(exchange); return; }
                if (path.equals("/v1/description")) { json(exchange, 200, description()); return; }
                if (path.equals("/v1/type")) { json(exchange, 200, readType(query)); return; }
                if (path.equals("/v1/types")) { json(exchange, 200, types(query)); return; }
            } else if (method.equals("DELETE") && path.equals("/v1/lease")) {
                json(exchange, 200, release(exchange));
                return;
            } else if (method.equals("POST")) {
                if (path.equals("/v1/publish")) { publish(exchange); return; }
                if (path.equals("/v1/lease")) { lease(exchange, body(exchange)); return; }
                JsonObject write = switch (path) {
                    case "/v1/rename/function" -> write(exchange, this::renameFunction);
                    case "/v1/rename/label" -> write(exchange, this::renameLabel);
                    case "/v1/create/function" -> write(exchange, this::createFunction);
                    case "/v1/rename/variable" -> write(exchange, this::renameVariable);
                    case "/v1/rename/variables" -> batch(exchange, this::renameVariable);
                    case "/v1/set/comments" -> batch(exchange, this::setComment);
                    case "/v1/set/signature" -> write(exchange, this::setSignature);
                    case "/v1/set/comment" -> write(exchange, this::setComment);
                    case "/v1/set/data" -> write(exchange, this::setData);
                    case "/v1/set/description" -> write(exchange, this::setDescription);
                    case "/v1/set/code-mode" -> write(exchange, this::setCodeMode);
                    case "/v1/set/equate" -> write(exchange, this::setEquate);
                    case "/v1/tag/function" -> write(exchange, this::tagFunction);
                    case "/v1/type" -> write(exchange, this::addType);
                    case "/v1/save" -> write(exchange, body -> {
                        if (program.isChanged()) program.save("save", TaskMonitor.DUMMY);
                        JsonObject answer = identity();
                        answer.addProperty("saved", true);
                        return answer;
                    });
                    default -> null;
                };
                if (write != null) { json(exchange, 200, write); return; }
                if (path.equals("/v1/stop")) {
                    JsonObject answer = new JsonObject();
                    answer.addProperty("stopping", true);
                    json(exchange, 200, answer);
                    new Thread(() -> { close(); System.exit(0); }).start();
                    return;
                }
            }
            throw new Failure(404, method + " " + path + " is not a call of this bridge");
        } catch (Failure failure) {
            error(exchange, failure.status, failure.getMessage());
        } catch (Exception error) {
            error(exchange, 500, error.toString());
        }
    }

    private JsonObject hello() {
        JsonObject answer = identity();
        answer.addProperty("protocol", PROTOCOL);
        answer.addProperty("build", BUILD);
        answer.addProperty("ghidra", Application.getApplicationVersion());
        answer.addProperty("functions", program.getFunctionManager().getFunctionCount());
        answer.addProperty("changed", program.isChanged());
        answer.addProperty("modification", program.getModificationNumber());
        if (leaseToken != null) {
            answer.addProperty("lease_holder", leaseHolder);
            answer.addProperty("lease_expires_in", Math.max(0, (leaseExpires - System.currentTimeMillis()) / 1000));
        }
        return answer;
    }

    /** What every answer is about. */
    private JsonObject identity() {
        JsonObject answer = new JsonObject();
        answer.addProperty("module", options.get("module"));
        answer.addProperty("project", options.get("project-id"));
        answer.addProperty("program", program.getName());
        answer.addProperty("language", program.getLanguageID().toString());
        answer.addProperty("image_base", hex(program.getImageBase()));
        return answer;
    }

    /** The names that say a review has not passed: Ghidra's placeholders. */
    private static final java.util.regex.Pattern PLACEHOLDER = java.util.regex.Pattern.compile(
        "^(param_\\d+|local_[0-9a-fA-F]+|[A-Za-z_][A-Za-z0-9_]*Var\\d+|extraout_[A-Z0-9]+"
        + "|in_[A-Z0-9]+|unaff_[A-Z0-9]+|undefined.*)$");

    private static boolean placeholder(String name) {
        return name != null && PLACEHOLDER.matcher(name).matches();
    }

    private static boolean undefined(DataType type) {
        if (type == null) return true;
        if (type instanceof ghidra.program.model.data.Undefined) return true;
        String name = type.getDisplayName();
        return name != null && name.startsWith("undefined");
    }

    /**
     * What a review has left in this function: parameters and locals Ghidra
     * still names itself or holds as `undefined`, and no plate comment. Null
     * when there are none — `filter=unfinished` and the finished-function bar
     * of the skill read this, one call each.
     */
    private JsonObject leftovers(Function function) {
        int parameters = 0, locals = 0, fragments = 0;
        for (Parameter parameter : function.getParameters()) {
            if (placeholder(parameter.getName()) || undefined(parameter.getDataType())) parameters++;
        }
        DecompileResults results = decompile(function);
        HighFunction high = results == null ? null : results.getHighFunction();
        if (high != null) {
            Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
            while (symbols.hasNext()) {
                HighSymbol symbol = symbols.next();
                if (symbol.isParameter()) continue;
                if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
                if (!placeholder(symbol.getName()) && !undefined(symbol.getDataType())) continue;
                // A register or `unique:` piece with a name Ghidra made up is
                // the decompiler splitting a value as a review types around
                // it, not a name the review missed.
                if (fragment(symbol.getStorage())) fragments++; else locals++;
            }
        }
        String plate = function.getComment();
        boolean noPlate = plate == null || plate.isBlank();
        if (parameters == 0 && locals == 0 && fragments == 0 && !noPlate) return null;
        JsonObject answer = new JsonObject();
        if (parameters > 0) answer.addProperty("params", parameters);
        if (locals > 0) answer.addProperty("locals", locals);
        if (fragments > 0) answer.addProperty("fragments", fragments);
        if (noPlate) answer.addProperty("no_plate", true);
        return answer;
    }

    /** A decompiler piece of a register or a `unique:` space, not a stored variable. */
    private static boolean fragment(ghidra.program.model.listing.VariableStorage storage) {
        if (storage == null) return false;
        return storage.isRegisterStorage() || storage.isUniqueStorage() || storage.isHashStorage();
    }

    /** A function a review has not passed: a placeholder parameter or local, or no plate. */
    private static boolean unfinished(JsonObject leftovers) {
        return leftovers.has("params") || leftovers.has("locals") || leftovers.has("no_plate");
    }

    private JsonObject item(Function function) {
        JsonObject item = new JsonObject();
        item.addProperty("entry", hex(function.getEntryPoint()));
        item.addProperty("name", function.getName());
        item.addProperty("name_source", function.getSymbol().getSource().toString());
        item.addProperty("size", function.getBody().getNumAddresses());
        item.addProperty("signature", function.getPrototypeString(false, false));
        addTags(item, function);
        return item;
    }

    /**
     * The functions, narrowed: `name_contains`, `address_from`/`address_to`
     * (their entries), `name_source` (a Ghidra `SourceType` such as
     * `USER_DEFINED`), and `filter=unfinished` — the functions a review has
     * not passed. That one decompiles every function to see its locals, and
     * says how many it checked in `summary`.
     */
    private JsonObject functions(Map<String, String> query) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 500), 5000);
        String filter = query.getOrDefault("filter", "");
        if (!filter.isEmpty() && !filter.equals("unfinished")) {
            throw new Failure(400, "filter is \"unfinished\" or left out");
        }
        boolean unfinished = filter.equals("unfinished");
        String contains = query.get("name_contains");
        String source = query.get("name_source");
        Long from = query.containsKey("address_from") ? address(query.get("address_from")).getOffset() : null;
        Long to = query.containsKey("address_to") ? address(query.get("address_to")).getOffset() : null;
        JsonArray matched = new JsonArray();
        int scanned = 0;
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            scanned++;
            if (contains != null && !function.getName().toLowerCase(java.util.Locale.ROOT)
                    .contains(contains.toLowerCase(java.util.Locale.ROOT))) continue;
            if (source != null && !function.getSymbol().getSource().toString().equalsIgnoreCase(source)) continue;
            long entry = function.getEntryPoint().getOffset();
            if (from != null && entry < from) continue;
            if (to != null && entry > to) continue;
            JsonObject leftovers = unfinished ? leftovers(function) : null;
            if (unfinished && (leftovers == null || !unfinished(leftovers))) continue;
            JsonObject item = item(function);
            if (leftovers != null) item.add("leftovers", leftovers);
            matched.add(item);
        }
        int total = matched.size();
        int start = Math.min(offset, total), end = Math.min(start + limit, total);
        JsonArray page = new JsonArray();
        for (int index = start; index < end; index++) page.add(matched.get(index));
        JsonObject answer = identity();
        answer.add("functions", page);
        if (end < total) answer.addProperty("next", end);
        if (unfinished) {
            JsonObject summary = new JsonObject();
            summary.addProperty("functions", scanned);
            summary.addProperty("unfinished", total);
            answer.add("summary", summary);
        }
        return answer;
    }

    /**
     * One function. `summary=1` leaves the decompiled C and the equates out —
     * signature, parameters, locals, plate comment and what is left to name —
     * for walking a module without its text.
     */
    private JsonObject function(String text, Map<String, String> query) throws Failure {
        boolean summary = "1".equals(query.get("summary")) || "true".equals(query.get("summary"));
        Function function = functionAt(text);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        answer.addProperty("name_source", function.getSymbol().getSource().toString());
        answer.addProperty("signature", function.getPrototypeString(false, false));
        addTags(answer, function);
        String plate = function.getComment();
        if (plate != null && !plate.isBlank()) answer.addProperty("plate", plate);
        JsonArray parameters = new JsonArray();
        for (Parameter parameter : function.getParameters()) {
            JsonObject item = new JsonObject();
            item.addProperty("ordinal", parameter.getOrdinal());
            item.addProperty("name", parameter.getName());
            item.addProperty("type", parameter.getDataType().getDisplayName());
            item.addProperty("storage", parameter.getVariableStorage().toString());
            parameters.add(item);
        }
        answer.add("parameters", parameters);
        DecompileResults results = decompile(function);
        HighFunction high = results == null ? null : results.getHighFunction();
        JsonArray locals = new JsonArray();
        if (high != null) {
            Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
            while (symbols.hasNext()) {
                HighSymbol symbol = symbols.next();
                if (symbol.isParameter()) continue;
                // An equate's name lives in the local map too: it is a constant, not a local.
                if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
                JsonObject item = new JsonObject();
                item.addProperty("name", symbol.getName());
                DataType type = symbol.getDataType();
                item.addProperty("type", type == null ? null : type.getDisplayName());
                item.addProperty("storage", symbol.getStorage().toString());
                Address first = symbol.getPCAddress();
                item.addProperty("first_use", first == null ? null : hex(first));
                // Ghidra's names for unnamed locals renumber when another is
                // named; a client addresses a local by storage and first use.
                // A name Ghidra still made up is not one — typing a local
                // alone leaves it unnamed, and `leftovers` agrees.
                item.addProperty("named", symbol.getSymbol() != null && !placeholder(symbol.getName()));
                locals.add(item);
            }
        }
        answer.add("locals", locals);
        JsonObject leftovers = leftovers(function);
        if (leftovers != null) answer.add("leftovers", leftovers);
        if (!summary) {
            answer.add("equates", equatesIn(function));
            answer.addProperty("c", results != null && results.getDecompiledFunction() != null
                               ? results.getDecompiledFunction().getC() : null);
        }
        if (results != null && !results.decompileCompleted()) {
            answer.addProperty("decompile_error", results.getErrorMessage());
        }
        return answer;
    }

    private static String kind(DataType type) {
        if (type instanceof ghidra.program.model.data.Structure) return "struct";
        if (type instanceof ghidra.program.model.data.Union) return "union";
        if (type instanceof ghidra.program.model.data.Enum) return "enum";
        if (type instanceof ghidra.program.model.data.TypeDef) return "typedef";
        if (type instanceof ghidra.program.model.data.FunctionDefinition) return "function";
        if (type instanceof ghidra.program.model.data.Pointer) return "pointer";
        if (type instanceof ghidra.program.model.data.Array) return "array";
        return "other";
    }

    /**
     * The types the program holds — what a review defined and what it used —
     * with their kind, size and origin: `program`, or the archive they came
     * from. `contains` narrows by name, `source` by origin, and `builtin=1`
     * adds Ghidra's own types, left out by default.
     */
    private JsonObject types(Map<String, String> query) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 500), 5000);
        String contains = query.get("contains");
        String source = query.get("source");
        // `kind` narrows by what the type is: `struct`, `union`, `enum`,
        // `typedef`, `function`, `pointer`, `array` — one, or several
        // separated by commas, because a description's type list wants the
        // four a review defines and nothing else.
        java.util.Set<String> kinds = new java.util.HashSet<>();
        if (query.get("kind") != null) {
            for (String part : query.get("kind").split(",")) {
                if (!part.trim().isEmpty()) kinds.add(part.trim().toLowerCase(java.util.Locale.ROOT));
            }
        }
        boolean builtins = "1".equals(query.get("builtin")) || "true".equals(query.get("builtin"));
        java.util.List<JsonObject> matched = new java.util.ArrayList<>();
        java.util.TreeSet<String> sources = new java.util.TreeSet<>();
        Iterator<DataType> all = program.getDataTypeManager().getAllDataTypes();
        while (all.hasNext()) {
            DataType type = all.next();
            if (type instanceof ghidra.program.model.data.BuiltInDataType && !builtins) continue;
            ghidra.program.model.data.SourceArchive here = type.getSourceArchive();
            sources.add(here == null || here.getSourceArchiveID() == null
                || here.getArchiveType() == ghidra.program.model.data.ArchiveType.PROGRAM
                ? "program" : here.getName());
            if (contains != null && !type.getName().toLowerCase(java.util.Locale.ROOT)
                    .contains(contains.toLowerCase(java.util.Locale.ROOT))) continue;
            ghidra.program.model.data.SourceArchive archive = type.getSourceArchive();
            String origin = archive == null || archive.getSourceArchiveID() == null
                || archive.getArchiveType() == ghidra.program.model.data.ArchiveType.PROGRAM
                ? "program" : archive.getName();
            if (source != null && !origin.equalsIgnoreCase(source)) continue;
            String what = kind(type);
            if (!kinds.isEmpty() && !kinds.contains(what)) continue;
            JsonObject item = new JsonObject();
            item.addProperty("name", type.getName());
            item.addProperty("path", type.getPathName());
            item.addProperty("kind", what);
            item.addProperty("size", type.getLength());
            item.addProperty("source", origin);
            String description = type.getDescription();
            if (description != null && !description.isEmpty()) item.addProperty("description", description);
            matched.add(item);
        }
        int total = matched.size();
        int start = Math.min(offset, total), end = Math.min(start + limit, total);
        JsonArray page = new JsonArray();
        for (int index = start; index < end; index++) page.add(matched.get(index));
        JsonObject answer = identity();
        answer.add("types", page);
        answer.addProperty("total", total);
        // Every origin the program's types hold, so `source` can be named
        // rather than guessed — the reviews' archive included.
        JsonArray origins = new JsonArray();
        sources.forEach(origins::add);
        answer.add("sources", origins);
        if (end < total) answer.addProperty("next", end);
        return answer;
    }

    /**
     * The names the function's instructions give their constants, once each:
     * the value, the enum, the member's comment, and where it is used.
     */
    private JsonArray equatesIn(Function function) {
        java.util.TreeMap<String, JsonObject> found = new java.util.TreeMap<>();
        InstructionIterator iterator = program.getListing().getInstructions(function.getBody(), true);
        while (iterator.hasNext()) {
            Address at = iterator.next().getAddress();
            for (ghidra.program.model.symbol.Equate equate : program.getEquateTable().getEquates(at)) {
                JsonObject item = found.computeIfAbsent(equate.getDisplayName(), name -> {
                    JsonObject entry = new JsonObject();
                    entry.addProperty("name", name);
                    entry.addProperty("value", "0x" + Long.toHexString(equate.getValue()).toUpperCase());
                    DataType type = equate.isEnumBased() && equate.isValidUUID()
                        ? program.getDataTypeManager().findDataTypeForID(equate.getEnumUUID()) : null;
                    if (type instanceof ghidra.program.model.data.Enum values) {
                        entry.addProperty("enum", values.getName());
                        String comment = values.getComment(name);
                        if (comment != null && !comment.isEmpty()) entry.addProperty("comment", comment);
                    }
                    entry.add("at", new JsonArray());
                    return entry;
                });
                item.getAsJsonArray("at").add(hex(at));
            }
        }
        JsonArray list = new JsonArray();
        found.values().forEach(list::add);
        return list;
    }

    /**
     * The function's instructions, all of them or a page: `from` (an address
     * in the function) and `limit`. A page that stops short names the next
     * instruction in `next`, which a client passes back as `from`: a large
     * function does not fit in one answer.
     */
    private JsonObject disassembly(String text, Map<String, String> query) throws Failure {
        Function function = functionAt(text);
        Address from = query.containsKey("from") ? address(query.get("from")) : null;
        int limit = Integer.MAX_VALUE;
        if (query.containsKey("limit")) {
            try {
                limit = Integer.parseInt(query.get("limit"));
            } catch (NumberFormatException error) {
                throw new Failure(400, "limit is a number");
            }
            if (limit < 1) throw new Failure(400, "limit is at least 1");
        }
        JsonArray instructions = new JsonArray();
        String next = null;
        InstructionIterator iterator = program.getListing().getInstructions(function.getBody(), true);
        while (iterator.hasNext()) {
            Instruction instruction = iterator.next();
            if (from != null && instruction.getAddress().compareTo(from) < 0) continue;
            if (instructions.size() == limit) {
                next = hex(instruction.getAddress());
                break;
            }
            JsonObject item = new JsonObject();
            item.addProperty("address", hex(instruction.getAddress()));
            try {
                item.addProperty("bytes", hexBytes(instruction.getBytes()));
            } catch (Exception ignored) {
                item.addProperty("bytes", "");
            }
            item.addProperty("text", instruction.toString());
            // Code read as 16-bit in a 32-bit program (set/code-mode) says so.
            ghidra.program.model.lang.Register opsize = program.getProgramContext().getRegister("opsize");
            if (opsize != null && program.getDefaultPointerSize() == 4) {
                java.math.BigInteger mode = instruction.getValue(opsize, false);
                if (mode != null && mode.signum() == 0) item.addProperty("bits", 16);
            }
            JsonArray references = new JsonArray();
            for (Reference reference : instruction.getReferencesFrom()) {
                // A stack or register operand is not a place in the module.
                if (reference.getToAddress().isMemoryAddress()) references.add(reference(reference));
            }
            item.add("references", references);
            JsonArray named = new JsonArray();
            for (ghidra.program.model.symbol.Equate equate
                     : program.getEquateTable().getEquates(instruction.getAddress())) {
                for (ghidra.program.model.symbol.EquateReference use : equate.getReferences(instruction.getAddress())) {
                    JsonObject name = new JsonObject();
                    name.addProperty("operand", use.getOpIndex());
                    name.addProperty("name", equate.getDisplayName());
                    named.add(name);
                }
            }
            if (named.size() > 0) item.add("equates", named);
            instructions.add(item);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.add("instructions", instructions);
        if (next != null) answer.addProperty("next", next);
        return answer;
    }

    private JsonObject xrefs(Map<String, String> query) throws Failure {
        JsonArray list = new JsonArray();
        if (query.containsKey("to")) {
            ReferenceIterator iterator = program.getReferenceManager().getReferencesTo(address(query.get("to")));
            while (iterator.hasNext()) list.add(reference(iterator.next()));
        } else if (query.containsKey("from")) {
            for (Reference reference : program.getReferenceManager().getReferencesFrom(address(query.get("from")))) {
                if (reference.getToAddress().isMemoryAddress()) list.add(reference(reference));
            }
        } else {
            throw new Failure(400, "xrefs needs to= or from=");
        }
        JsonObject answer = identity();
        answer.add("references", list);
        return answer;
    }

    private JsonObject data(Map<String, String> query, boolean strings) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 500), 5000);
        JsonArray list = new JsonArray();
        DataIterator iterator = program.getListing().getDefinedData(true);
        int index = 0;
        boolean more = false;
        while (iterator.hasNext()) {
            Data item = iterator.next();
            if (strings && !item.hasStringValue()) continue;
            if (index++ < offset) continue;
            if (list.size() == limit) { more = true; break; }
            JsonObject entry = new JsonObject();
            entry.addProperty("address", hex(item.getAddress()));
            entry.addProperty("type", item.getDataType().getDisplayName());
            entry.addProperty("length", item.getLength());
            if (item.getPrimarySymbol() != null) entry.addProperty("name", item.getPrimarySymbol().getName());
            if (strings) {
                Object value = item.getValue();
                entry.addProperty("value", value == null ? null : value.toString());
            }
            list.add(entry);
        }
        JsonObject answer = identity();
        answer.add(strings ? "strings" : "data", list);
        if (more) answer.addProperty("next", offset + limit);
        return answer;
    }

    /**
     * Saves the program if it changed, runs ExportCode on it here, and
     * answers with the artifact itself. The headers say what was exported;
     * the client stores the body and decides what that publish is.
     */
    private void publish(HttpExchange exchange) throws Exception {
        // A preview exports the same artifact and works out the same conflicts
        // without saving the program or merging types into the shared archive:
        // what a publish would store, before it is stored.
        java.util.Map<String, String> parameters = query(exchange.getRequestURI().getRawQuery());
        boolean dryRun = "1".equals(parameters.get("dry_run"));
        // `take_type_conflicts`: this publish's version of a conflicting type
        // replaces the shared one — the explicit exception to "choosing is a
        // person's", for a layout that was published wrong. An enum is never
        // taken: a member's value clashing means one of the two is wrong, and
        // an overwrite would break the module that added the other. With
        // `dry_run` it answers what would be taken, and nothing is written.
        boolean take = "1".equals(parameters.get("take_type_conflicts"));
        if (!dryRun && program.isChanged()) program.save("publish", TaskMonitor.DUMMY);
        File out = File.createTempFile("owner-export-", ".json");
        try {
            ExportCode export = new ExportCode();
            export.setScriptArgs(new String[] {out.getPath()});
            PrintWriter log = new PrintWriter(System.out, true);
            export.execute(new GhidraState(null, project.getProject(), program, null, null, null),
                           new ScriptControls(log, log, TaskMonitor.DUMMY));
            byte[] artifact = Files.readAllBytes(out.toPath());
            if (artifact.length == 0) throw new Failure(500, "the export wrote nothing");
            published = Harvest.of(program, options.get("module"), options.get("project-id"));
            Merge merge = mergeReviewTypes(!dryRun, take);
            exchange.getResponseHeaders().set("X-Owner-Dry-Run", Boolean.toString(dryRun));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("X-Owner-Modification", Long.toString(program.getModificationNumber()));
            exchange.getResponseHeaders().set("X-Owner-Reviewed", Boolean.toString(published.reviewed));
            if (!merge.conflicts.isEmpty()) {
                exchange.getResponseHeaders().set("X-Owner-Type-Conflicts", String.join(",", merge.conflicts));
            }
            if (!merge.taken.isEmpty()) {
                exchange.getResponseHeaders().set("X-Owner-Type-Taken", String.join(",", merge.taken));
            }
            // `NAME=module,…`: which module wrote the shared version each type
            // names — the conflict it stayed in, or the one this publish
            // replaced.
            StringBuilder origins = new StringBuilder();
            for (java.util.Map.Entry<String, String> origin : merge.origins.entrySet()) {
                if (origin.getValue() == null || origin.getValue().isEmpty()) continue;
                if (origins.length() > 0) origins.append(',');
                origins.append(origin.getKey()).append('=').append(origin.getValue());
            }
            if (origins.length() > 0) {
                exchange.getResponseHeaders().set("X-Owner-Type-Origins", origins.toString());
            }
            exchange.sendResponseHeaders(200, artifact.length);
            try (OutputStream body = exchange.getResponseBody()) { body.write(artifact); }
        } finally {
            out.delete();
        }
    }

    private FileChannel lockChannel() throws Exception {
        File lock = new File(reviewTypes.getPath() + ".lock");
        return FileChannel.open(lock.toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE);
    }

    /** What a merge of this review's types into the shared archive found or did. */
    private static final class Merge {
        /** The names a publish would leave in this module only. */
        final java.util.List<String> conflicts = new java.util.ArrayList<>();
        /** The names this publish replaced in the shared archive — or would, in a preview. */
        final java.util.List<String> taken = new java.util.ArrayList<>();
        /** For each conflict, the module that wrote the shared version, when the sidecar knows it. */
        final java.util.TreeMap<String, String> origins = new java.util.TreeMap<>();
        /** A shared type was added or replaced: the sidecar has something to record. */
        boolean written;
    }

    /**
     * Puts this review's types into the shared archive, under its lock, for
     * the modules opened after it. A type the archive already has under the
     * name is left alone when it is the same, and reported when it is not:
     * the program keeps its own, and choosing is a person's (§16.5) — a
     * publish with `take` is that choice, made once, and replaces the shared
     * copy with this review's. A typedef and the structure it names are
     * shared separately and merged together: a corrected typedef over a
     * structure that kept the old layout would lay out wrong.
     * The lock is held for the length of the merge, a second or so.
     */
    private Merge mergeReviewTypes(boolean apply, boolean take) throws Exception {
        Merge merge = new Merge();
        java.util.TreeMap<String, String> mine = Harvest.reviewTypes(program);
        if (reviewTypes == null || mine.isEmpty()) return merge;
        if (!apply) {
            if (!reviewTypes.isFile()) return merge;
            try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
                FileDataTypeManager shared = FileDataTypeManager.openFileArchive(reviewTypes, false);
                try {
                    mergeInto(shared, mine, merge, false, take, readOrigins());
                } finally {
                    shared.close();
                }
            }
            return merge;
        }
        reviewTypes.getParentFile().mkdirs();
        try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
            FileDataTypeManager shared = reviewTypes.isFile()
                ? FileDataTypeManager.openFileArchive(reviewTypes, true)
                : FileDataTypeManager.createFileArchive(reviewTypes, program.getLanguageID(),
                      program.getCompilerSpec().getCompilerSpecID());
            try {
                JsonObject origins = readOrigins();
                boolean changed = false;
                int transaction = shared.startTransaction("review types of " + options.get("module"));
                try {
                    changed = mergeInto(shared, mine, merge, true, take, origins);
                } finally {
                    shared.endTransaction(transaction, true);
                }
                if (changed) shared.save();
                if (merge.written) writeOrigins(origins);
            } finally {
                shared.close();
            }
        }
        return merge;
    }

    /**
     * The merge itself, for a preview and for a publish alike. A preview only
     * reads — the archive is opened read-only there, so an enum is compared on
     * the side and never grown.
     */
    private boolean mergeInto(FileDataTypeManager shared, java.util.TreeMap<String, String> mine, Merge merge,
                              boolean apply, boolean take, JsonObject origins) throws Exception {
        boolean changed = false;
        String module = options.get("module");
        java.util.TreeMap<String, DataType> ours = new java.util.TreeMap<>();
        for (String name : mine.keySet()) {
            DataType named = find(program.getDataTypeManager(), name);
            if (named == null) continue;
            ours.put(named.getName(), named);
            if (named instanceof ghidra.program.model.data.TypeDef def) {
                DataType base = def.getBaseDataType();
                if (base != null && !base.getName().equals(named.getName())
                    && base.getDataTypeManager() == program.getDataTypeManager()) {
                    ours.putIfAbsent(base.getName(), base);
                }
            }
        }
        for (java.util.Map.Entry<String, DataType> entry : ours.entrySet()) {
            String name = entry.getKey();
            DataType here = entry.getValue();
            java.util.List<DataType> there = new java.util.ArrayList<>();
            shared.findDataTypes(name, there);
            if (there.isEmpty()) {
                if (!apply) continue;
                shared.resolve(here, DataTypeConflictHandler.KEEP_HANDLER);
                changed = true;
                merge.written = true;
                recordOrigin(origins, name, module);
                continue;
            }
            if (!apply) {
                if (conflictsWith(here, there.get(0))) {
                    if (take && replaceable(here, there.get(0))) {
                        merge.taken.add(name);
                        merge.origins.put(name, originOf(origins, name));
                    } else {
                        recordConflict(merge, origins, name);
                    }
                }
                continue;
            }
            DataType theirs = there.get(0);
            if (theirs instanceof ghidra.program.model.data.Enum sharedEnum
                && here instanceof ghidra.program.model.data.Enum ownEnum) {
                int merged = mergeEnum(ownEnum, sharedEnum);
                if (merged < 0) recordConflict(merge, origins, name);
                else if (merged > 0) changed = true;
            } else if (!theirs.isEquivalent(here)) {
                if (take && replaceable(here, theirs)) {
                    merge.taken.add(name);
                    merge.origins.put(name, originOf(origins, name));
                    replaceShared(shared, theirs, here);
                    changed = true;
                    merge.written = true;
                    recordOrigin(origins, name, module);
                } else {
                    recordConflict(merge, origins, name);
                }
            } else {
                int merged = mergeComments(here, theirs);
                if (merged < 0) recordConflict(merge, origins, name);
                else if (merged > 0) changed = true;
            }
        }
        return changed;
    }

    /** A take replaces a structure, a union or a typedef — never an enum. */
    private static boolean replaceable(DataType own, DataType shared) {
        return !(own instanceof ghidra.program.model.data.Enum)
            && !(shared instanceof ghidra.program.model.data.Enum);
    }

    /** Would a publish report this type? The same tests as the merge, without writing. */
    private static boolean conflictsWith(DataType own, DataType shared) {
        if (shared instanceof ghidra.program.model.data.Enum theirs
            && own instanceof ghidra.program.model.data.Enum mine) {
            return enumConflict(mine, theirs);
        }
        return !shared.isEquivalent(own) && commentsConflict(own, shared);
    }

    private static void recordConflict(Merge merge, JsonObject origins, String name) {
        merge.conflicts.add(name);
        merge.origins.put(name, originOf(origins, name));
    }

    /**
     * The shared archive's copy of a type replaced by this review's. The only
     * caller is a publish with `take_type_conflicts`, which is the person's
     * choice made explicit; a type the archive cannot replace — one another
     * type still holds — stops the publish with 409 rather than leaving half
     * of a correction behind.
     */
    private static void replaceShared(FileDataTypeManager shared, DataType theirs, DataType ours) throws Exception {
        try {
            shared.replaceDataType(theirs, ours, true);
        } catch (Exception error) {
            throw new Failure(409, theirs.getName() + " cannot replace the shared " + theirs.getName()
                              + ": " + error.getMessage());
        }
    }

    /** The module that last wrote each shared type, in a sidecar beside the archive. */
    private File originFile() {
        return new File(reviewTypes.getPath() + ".origin.json");
    }

    private JsonObject readOrigins() {
        File file = originFile();
        if (!file.isFile()) return new JsonObject();
        try (java.io.Reader reader = new java.io.InputStreamReader(new java.io.FileInputStream(file),
                                                                   java.nio.charset.StandardCharsets.UTF_8)) {
            com.google.gson.JsonElement read = com.google.gson.JsonParser.parseReader(reader);
            return read.isJsonObject() ? read.getAsJsonObject() : new JsonObject();
        } catch (Exception error) {
            System.out.println("OWNER ORIGINS unreadable: " + error.getMessage());
            return new JsonObject();
        }
    }

    private void writeOrigins(JsonObject origins) {
        try (java.io.Writer writer = new java.io.OutputStreamWriter(new java.io.FileOutputStream(originFile()),
                                                                    java.nio.charset.StandardCharsets.UTF_8)) {
            writer.write(origins.toString());
        } catch (Exception error) {
            System.out.println("OWNER ORIGINS not written: " + error.getMessage());
        }
    }

    private static void recordOrigin(JsonObject origins, String name, String module) {
        if (module == null || module.isEmpty()) return;
        JsonObject entry = new JsonObject();
        entry.addProperty("module", module);
        entry.addProperty("at", java.time.Instant.now().toString());
        origins.add(name, entry);
    }

    private static String originOf(JsonObject origins, String name) {
        if (!origins.has(name) || !origins.get(name).isJsonObject()) return "";
        JsonObject entry = origins.getAsJsonObject(name);
        return entry.has("module") ? entry.get("module").getAsString() : "";
    }

    private static boolean enumConflict(ghidra.program.model.data.Enum own,
                                        ghidra.program.model.data.Enum shared) {
        for (String name : own.getNames()) {
            long value = own.getValue(name);
            if (shared.contains(name) ? shared.getValue(name) != value : shared.contains(value)) return true;
        }
        return false;
    }

    private static boolean commentsConflict(DataType own, DataType shared) {
        DataType ownBase = own instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : own;
        DataType sharedBase = shared instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : shared;
        if (!(ownBase instanceof ghidra.program.model.data.Composite mine)
            || !(sharedBase instanceof ghidra.program.model.data.Composite theirs)) return true;
        return !uncommented(mine).isEquivalent(uncommented(theirs));
    }

    /**
     * An enum grows from module to module — the ports one module writes,
     * then the ports the next one does — so the shared one takes this
     * review's members it lacks, and this review's comment where it has one
     * and the shared one's differs: the review that published last read
     * the code last. A member whose value differs, or a value another name
     * holds, is a conflict, and nothing of that enum is merged. Answers the
     * number of changes, or -1 for a conflict.
     */
    private static int mergeEnum(ghidra.program.model.data.Enum own, ghidra.program.model.data.Enum shared) {
        for (String name : own.getNames()) {
            long value = own.getValue(name);
            if (shared.contains(name) ? shared.getValue(name) != value : shared.contains(value)) return -1;
        }
        int changes = 0;
        for (String name : own.getNames()) {
            long value = own.getValue(name);
            String comment = own.getComment(name);
            boolean commented = comment != null && !comment.isEmpty();
            if (!shared.contains(name)) {
                shared.add(name, value, commented ? comment : "");
                changes++;
            } else if (commented && !comment.equals(shared.getComment(name))) {
                shared.remove(name);
                shared.add(name, value, comment);
                changes++;
            }
        }
        String description = own.getDescription();
        if (description != null && !description.isEmpty() && !description.equals(shared.getDescription())) {
            shared.setDescription(description);
            changes++;
        }
        return changes;
    }

    /**
     * A structure that differs from the shared one only in its comments and
     * description is the same structure better explained: the shared one
     * takes this review's comments. Answers the number of changes, or -1
     * when the structures differ in more than that.
     */
    private static int mergeComments(DataType own, DataType shared) {
        DataType ownBase = own instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : own;
        DataType sharedBase = shared instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : shared;
        if (!(ownBase instanceof ghidra.program.model.data.Composite mine)
            || !(sharedBase instanceof ghidra.program.model.data.Composite theirs)) return -1;
        if (!uncommented(mine).isEquivalent(uncommented(theirs))) return -1;
        int changes = 0;
        ghidra.program.model.data.DataTypeComponent[] from = mine.getDefinedComponents();
        ghidra.program.model.data.DataTypeComponent[] to = theirs.getDefinedComponents();
        for (int i = 0; i < from.length && i < to.length; i++) {
            String comment = from[i].getComment();
            if (comment != null && !comment.isEmpty() && !comment.equals(to[i].getComment())) {
                to[i].setComment(comment);
                changes++;
            }
        }
        for (DataType[] pair : new DataType[][] {{own, shared}, {ownBase, sharedBase}}) {
            String description = pair[0].getDescription();
            if (description != null && !description.isEmpty() && !description.equals(pair[1].getDescription())) {
                pair[1].setDescription(description);
                changes++;
            }
        }
        return changes;
    }

    /** A copy of a structure with no comments and no description: its shape alone. */
    private static DataType uncommented(ghidra.program.model.data.Composite composite) {
        ghidra.program.model.data.Composite copy = (ghidra.program.model.data.Composite) composite.copy(null);
        for (ghidra.program.model.data.DataTypeComponent component : copy.getDefinedComponents()) {
            component.setComment(null);
        }
        copy.setDescription(null);
        return copy;
    }

    /** The review document harvested by the last publish. */
    private void review(HttpExchange exchange) throws Exception {
        if (published == null) throw new Failure(409, "nothing was published by this owner yet");
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.getResponseHeaders().set("X-Owner-Reviewed", Boolean.toString(published.reviewed));
        exchange.sendResponseHeaders(200, published.bytes.length);
        try (OutputStream body = exchange.getResponseBody()) { body.write(published.bytes); }
    }

    /**
     * The description as the last publish took it, as Markdown; 204 when it
     * had none. The client stores it as an object of its own.
     */
    private void publishedDescription(HttpExchange exchange) throws Exception {
        if (published == null) throw new Failure(409, "nothing was published by this owner yet");
        if (published.description == null) {
            exchange.sendResponseHeaders(204, -1);
            exchange.close();
            return;
        }
        exchange.getResponseHeaders().set("Content-Type", "text/markdown; charset=utf-8");
        exchange.sendResponseHeaders(200, published.description.length);
        try (OutputStream body = exchange.getResponseBody()) { body.write(published.description); }
    }

    /** The description as the program holds it now, with its sections. */
    private JsonObject description() {
        String text = Harvest.description(program);
        JsonObject answer = identity();
        if (text == null) {
            answer.add("text", com.google.gson.JsonNull.INSTANCE);
        } else {
            answer.addProperty("text", text);
        }
        JsonArray sections = new JsonArray();
        Harvest.sections(text).forEach(sections::add);
        answer.add("sections", sections);
        answer.addProperty("bytes", text == null ? 0 : text.getBytes(StandardCharsets.UTF_8).length);
        return answer;
    }

    /**
     * The module's description, whole or one `## ` section of it: `text` is
     * the Markdown (empty clears it, or removes the section), `section` the
     * heading whose body it replaces.
     */
    private JsonObject setDescription(JsonObject body) throws Exception {
        if (!body.has("text") || body.get("text").isJsonNull()) throw new Failure(400, "text is required");
        String text = body.get("text").getAsString();
        String section = string(body, "section", null);
        String next;
        if (section == null || section.isEmpty()) {
            next = Harvest.normalized(text);
        } else {
            String heading = section.startsWith("## ") ? section.substring(3).trim() : section.trim();
            if (heading.isEmpty() || heading.contains("\n")) throw new Failure(400, "section is one heading's words");
            next = Harvest.replaceSection(Harvest.description(program), heading, text);
        }
        if (next != null && next.getBytes(StandardCharsets.UTF_8).length > Harvest.DESCRIPTION_LIMIT) {
            throw new Failure(413, "a description is at most " + Harvest.DESCRIPTION_LIMIT / 1024 + " KiB");
        }
        Harvest.setDescription(program, next);
        return description();
    }

    // MARK: - The lease

    private void lease(HttpExchange exchange, JsonObject body) throws Exception {
        expireLease();
        String holder = string(body, "holder", "a client");
        // The same holder asking again is a host that lost its token — a
        // server restarted while this owner ran on: it takes the lease over.
        if (leaseToken != null && leaseToken.length() > 0 && holder.equals(leaseHolder)) {
            System.out.println("OWNER LEASE TAKEN OVER by " + holder);
            if (program.isChanged()) program.save("lease taken over by " + holder, TaskMonitor.DUMMY);
            leaseToken = null;
        }
        if (leaseToken != null) {
            JsonObject refused = new JsonObject();
            refused.addProperty("error", "the module is leased to " + leaseHolder);
            refused.addProperty("holder", leaseHolder);
            refused.addProperty("expires_in", (leaseExpires - System.currentTimeMillis()) / 1000);
            json(exchange, 409, refused);
            return;
        }
        leaseTtl = Math.max(30, Math.min(integer(body, "ttl", 900), 86400)) * 1000L;
        leaseToken = UUID.randomUUID().toString();
        leaseHolder = holder;
        leaseExpires = System.currentTimeMillis() + leaseTtl;
        System.out.println("OWNER LEASE " + holder);
        JsonObject answer = identity();
        answer.addProperty("token", leaseToken);
        answer.addProperty("expires_in", leaseTtl / 1000);
        json(exchange, 200, answer);
    }

    private JsonObject release(HttpExchange exchange) throws Exception {
        requireLease(exchange);
        if (program.isChanged()) program.save("lease released by " + leaseHolder, TaskMonitor.DUMMY);
        System.out.println("OWNER RELEASE " + leaseHolder);
        leaseToken = null;
        leaseHolder = null;
        JsonObject answer = identity();
        answer.addProperty("released", true);
        return answer;
    }

    private void expireLease() {
        if (leaseToken == null || System.currentTimeMillis() < leaseExpires) return;
        System.out.println("OWNER EXPIRED " + leaseHolder);
        try {
            if (program.isChanged()) program.save("lease of " + leaseHolder + " expired", TaskMonitor.DUMMY);
        } catch (Exception error) {
            System.err.println("OWNER save on expiry: " + error);
        }
        leaseToken = null;
        leaseHolder = null;
    }

    private void requireLease(HttpExchange exchange) throws Failure {
        expireLease();
        String token = exchange.getRequestHeaders().getFirst("X-Lease");
        if (leaseToken == null) throw new Failure(403, "take the write lease first: POST /v1/lease");
        if (!leaseToken.equals(token)) throw new Failure(403, "the module is leased to " + leaseHolder);
        leaseExpires = System.currentTimeMillis() + leaseTtl;
    }

    // MARK: - Writes

    private interface Change {
        JsonObject apply(JsonObject body) throws Exception;
    }

    /**
     * One change: under the lease, in a transaction of its own that is
     * committed only if the change succeeded. A refused change rolls back
     * itself and nothing before it — the lesson of phase 0.
     */
    private JsonObject write(HttpExchange exchange, Change change) throws Exception {
        requireLease(exchange);
        JsonObject body = body(exchange);
        int transaction = program.startTransaction(exchange.getRequestURI().getPath());
        boolean done = false;
        try {
            JsonObject answer = change.apply(body);
            done = true;
            System.out.println("OWNER CHANGE " + leaseHolder + " " + exchange.getRequestURI().getPath()
                               + " " + body);
            return answer;
        } finally {
            program.endTransaction(transaction, done);
        }
    }

    /**
     * Several changes of one kind in one call — `{"items": [{…}, …]}` — each
     * in a transaction of its own, so one refused entry leaves the others
     * done: a function with fifteen locals is one call, and the answer says
     * which entries applied and why the others did not.
     */
    private JsonObject batch(HttpExchange exchange, Change change) throws Exception {
        requireLease(exchange);
        JsonObject body = body(exchange);
        JsonElement items = body.get("items");
        if (items == null || !items.isJsonArray()) throw new Failure(400, "items is a list of changes");
        JsonArray requests = items.getAsJsonArray();
        if (requests.size() > 200) throw new Failure(400, "items holds at most 200 changes");
        JsonArray answers = new JsonArray();
        for (JsonElement element : requests) {
            if (!element.isJsonObject()) {
                JsonObject refused = new JsonObject();
                refused.addProperty("ok", false);
                refused.addProperty("error", "an item is an object");
                answers.add(refused);
                continue;
            }
            int transaction = program.startTransaction("batch item");
            boolean done = false;
            try {
                JsonObject answer = change.apply(element.getAsJsonObject()).deepCopy();
                answer.addProperty("ok", true);
                answers.add(answer);
                done = true;
            } catch (Failure failure) {
                JsonObject refused = new JsonObject();
                refused.addProperty("ok", false);
                refused.addProperty("status", failure.status);
                refused.addProperty("error", failure.getMessage());
                answers.add(refused);
            } catch (Exception error) {
                JsonObject refused = new JsonObject();
                refused.addProperty("ok", false);
                refused.addProperty("error", error.toString());
                answers.add(refused);
            } finally {
                program.endTransaction(transaction, done);
            }
        }
        System.out.println("OWNER BATCH " + leaseHolder + " "
                           + exchange.getRequestURI().getPath() + " " + answers.size());
        JsonObject answer = identity();
        answer.add("items", answers);
        return answer;
    }

    private JsonObject renameFunction(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        Function function = program.getFunctionManager().getFunctionAt(at);
        if (function == null) {
            // A label at the address is what a caller usually meant: a rename
            // here would silently rename the function around it (see the
            // skill's `ghidra_label`). Refused, with where the name belongs.
            Symbol atAddress = program.getSymbolTable().getPrimarySymbol(at);
            if (atAddress != null && atAddress.getSymbolType() == ghidra.program.model.symbol.SymbolType.LABEL) {
                throw new Failure(409, hex(at) + " is a label, not a function's entry: name it with "
                                  + "/v1/rename/label");
            }
            function = program.getFunctionManager().getFunctionContaining(at);
        }
        if (function == null) throw new Failure(404, "no function at " + hex(at));
        String name = required(body, "name");
        // Ghidra takes `*Name` for a name; C, the panel and a reader do not.
        if (!name.matches("[A-Za-z_][A-Za-z0-9_]*")) throw new Failure(400, name + " is not a C identifier");
        // Ghidra would make a duplicate `Foo_1`; a client gets the refusal.
        for (Symbol other : program.getSymbolTable().getGlobalSymbols(name)) {
            if (!other.getAddress().equals(function.getEntryPoint())) {
                throw new Failure(409, name + " already names " + hex(other.getAddress()));
            }
        }
        try {
            function.setName(name, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage());
        }
        why(function.getEntryPoint(), body);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        // Where the address really pointed, when it was not the entry: a
        // client that meant a label sees it here without rereading the C.
        answer.addProperty("matched", function.getEntryPoint().equals(at) ? "entry" : "containing");
        return answer;
    }

    /**
     * The label at `address` named: a jump target the decompiler prints as
     * `LAB_<address>` is a step of the flow — an error exit, a loop's head,
     * the place a structure starts being read — and its name belongs on the
     * label, not on the function around it. A function's entry is refused
     * (that is `renameFunction`'s call), and so is an address no instruction
     * starts at: a label marks code.
     */
    private JsonObject renameLabel(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        String name = string(body, "name", null);
        if (program.getFunctionManager().getFunctionAt(at) != null) {
            throw new Failure(409, hex(at) + " is a function's entry: rename the function with /v1/rename/function");
        }
        if (program.getListing().getInstructionAt(at) == null) {
            throw new Failure(404, "no instruction starts at " + hex(at) + ": a label marks code");
        }
        // An empty name takes the label away — a name given to a jump target
        // by mistake leaves nothing behind, as an empty comment clears one.
        if (name != null && name.isEmpty()) {
            Symbol symbol = program.getSymbolTable().getPrimarySymbol(at);
            if (symbol == null || symbol.getSymbolType() != ghidra.program.model.symbol.SymbolType.LABEL) {
                throw new Failure(404, "no label at " + hex(at) + " to delete");
            }
            String removed = symbol.getName();
            try {
                symbol.delete();
            } catch (Exception error) {
                throw new Failure(409, error.getMessage());
            }
            JsonObject answer = identity();
            answer.addProperty("address", hex(at));
            answer.addProperty("deleted", removed);
            return answer;
        }
        if (name == null) throw new Failure(400, "give a name, or an empty one to delete the label");
        if (!name.matches("[A-Za-z_][A-Za-z0-9_]*")) throw new Failure(400, name + " is not a C identifier");
        for (Symbol other : program.getSymbolTable().getGlobalSymbols(name)) {
            if (!other.getAddress().equals(at)) {
                throw new Failure(409, name + " already names " + hex(other.getAddress()));
            }
        }
        try {
            Symbol primary = program.getSymbolTable().getPrimarySymbol(at);
            if (primary != null && !primary.isDynamic()) primary.setName(name, SourceType.USER_DEFINED);
            else program.getSymbolTable().createLabel(at, name, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage());
        }
        why(at, body);
        JsonObject answer = identity();
        answer.addProperty("address", hex(at));
        answer.addProperty("name", name);
        return answer;
    }

    /**
     * A Ghidra tag on the function at `address` — a mark of what a function
     * is that the code itself does not say. This is how a review says a
     * function is an EDK2 library routine the module statically links in
     * that the automatic detection did not recognise: the tag `library`
     * makes ExportCode write the function at the `library` review level,
     * complete as it is, whatever its name or comments. The function is the
     * one containing the address, as with the other function writes; a tag
     * name is letters, digits, '.', '_' and '-', up to 40 of them. An empty
     * `tag`, or `none`, removes the `library` tag. The answer lists the
     * function's tags, sorted.
     */
    private JsonObject tagFunction(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        String tag = string(body, "tag", null);
        if (tag == null || tag.isEmpty() || tag.equalsIgnoreCase("none")) {
            function.removeTag("library");
        } else {
            if (!tag.matches("[A-Za-z0-9._-]{1,40}")) {
                throw new Failure(400, tag + " is not a tag name: letters, digits, '.', '_' and '-', "
                                  + "up to 40");
            }
            function.addTag(tag);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        addTags(answer, function);
        return answer;
    }

    /**
     * The function's Ghidra tags, sorted, and — for a function the export
     * writes at the `library` level — `library`: why, `edk2_name` or `tag`.
     */
    private static void addTags(JsonObject answer, Function function) {
        JsonArray tags = new JsonArray();
        java.util.TreeSet<String> sorted = new java.util.TreeSet<>();
        for (ghidra.program.model.listing.FunctionTag held : function.getTags()) {
            if (held != null) sorted.add(held.getName());
        }
        for (String name : sorted) tags.add(name);
        answer.add("tags", tags);
        String basis = ExportCode.libraryBasis(function);
        if (basis != null) answer.addProperty("library", basis);
    }

    /**
     * A function at `address` where Ghidra made none: code reached only
     * through a table — a services table's slot, a PPI's member — that no
     * call names. The instructions are disassembled first when they are not
     * yet; `name`, when given, names it as a rename would. One already there
     * is answered as it is.
     */
    private JsonObject createFunction(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        Function function = program.getFunctionManager().getFunctionAt(at);
        boolean created = false;
        if (function == null) {
            if (program.getListing().getInstructionAt(at) == null) {
                if (program.getListing().getDefinedDataContaining(at) != null) {
                    throw new Failure(409, hex(at) + " is defined data, not code");
                }
                new ghidra.app.cmd.disassemble.DisassembleCommand(at, null, true).applyTo(program, TaskMonitor.DUMMY);
                if (program.getListing().getInstructionAt(at) == null) {
                    throw new Failure(400, "no instruction decodes at " + hex(at));
                }
            }
            ghidra.app.cmd.function.CreateFunctionCmd command = new ghidra.app.cmd.function.CreateFunctionCmd(at);
            if (!command.applyTo(program, TaskMonitor.DUMMY)) {
                throw new Failure(400, "Ghidra made no function at " + hex(at)
                    + (command.getStatusMsg() == null ? "" : ": " + command.getStatusMsg()));
            }
            function = program.getFunctionManager().getFunctionAt(at);
            created = true;
        }
        if (body.has("name") && !body.get("name").isJsonNull()) {
            JsonObject rename = body.deepCopy();
            rename.addProperty("address", hex(at));
            renameFunction(rename);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        answer.addProperty("created", created);
        answer.addProperty("size", function.getBody().getNumAddresses());
        return answer;
    }

    /**
     * The code in [start, end) read as 16-bit or as 32-bit x86. A 32-bit
     * program decodes the reset vector's real-mode code as 32-bit, which
     * reads it wrongly: the operand and address size live in the x86
     * context (`opsize`, `addrsize`), not in the bytes. The instructions in
     * the range are cleared, the context set, the range disassembled again
     * from `start` without leaving it, and every function that lost or
     * gained instructions has its body fixed. The segment model is left as
     * it is: an address is still an offset, not segment × 16 + offset.
     */
    private JsonObject setCodeMode(JsonObject body) throws Exception {
        Address start = address(required(body, "start"));
        Address end = address(required(body, "end"));
        int bits = integer(body, "bits", 0);
        if (bits != 16 && bits != 32) throw new Failure(400, "bits is 16 or 32");
        if (end.compareTo(start) <= 0) throw new Failure(400, "end is past start: the range is [start, end)");
        Address last = end.subtract(1);
        if (!program.getMemory().contains(start, last)) {
            throw new Failure(400, hex(start) + ".." + hex(end) + " is not all in the program's memory");
        }
        ghidra.program.model.lang.Register addrsize = program.getProgramContext().getRegister("addrsize");
        ghidra.program.model.lang.Register opsize = program.getProgramContext().getRegister("opsize");
        if (addrsize == null || opsize == null) {
            throw new Failure(400, program.getLanguageID() + " has no x86 operand-size context");
        }
        ghidra.program.model.address.AddressSet range = new ghidra.program.model.address.AddressSet(start, last);

        // Instructions that reach into the range from before it go too:
        // their bytes are the range's.
        java.util.Set<Address> touched = new java.util.TreeSet<>();
        Instruction before = program.getListing().getInstructionContaining(start);
        Address clearFrom = before != null ? before.getMinAddress() : start;
        Instruction after = program.getListing().getInstructionContaining(last);
        Address clearTo = after != null ? after.getMaxAddress() : last;
        for (Instruction instruction : program.getListing().getInstructions(
                 new ghidra.program.model.address.AddressSet(clearFrom, clearTo), true)) {
            Function owner = program.getFunctionManager().getFunctionContaining(instruction.getMinAddress());
            if (owner != null) touched.add(owner.getEntryPoint());
        }
        if (program.getListing().getDefinedDataContaining(start) != null
            || program.getListing().getDefinedData(range, true).hasNext()) {
            throw new Failure(409, "defined data lies in " + hex(start) + ".." + hex(end) + ": clear it first");
        }
        program.getListing().clearCodeUnits(clearFrom, clearTo, false);

        java.math.BigInteger value = java.math.BigInteger.valueOf(bits == 16 ? 0 : 1);
        program.getProgramContext().setValue(addrsize, start, last, value);
        program.getProgramContext().setValue(opsize, start, last, value);

        ghidra.app.cmd.disassemble.DisassembleCommand disassemble =
            new ghidra.app.cmd.disassemble.DisassembleCommand(new ghidra.program.model.address.AddressSet(start), range, true);
        disassemble.applyTo(program, TaskMonitor.DUMMY);
        // What the range lost before `start` and after its last instruction
        // is decoded again in the mode that was there.
        if (clearFrom.compareTo(start) < 0) {
            new ghidra.app.cmd.disassemble.DisassembleCommand(clearFrom, null, true).applyTo(program, TaskMonitor.DUMMY);
        }

        Function atStart = program.getFunctionManager().getFunctionAt(start);
        if (atStart != null) touched.add(start);
        JsonArray functions = new JsonArray();
        for (Address entry : touched) {
            Function function = program.getFunctionManager().getFunctionAt(entry);
            if (function == null) continue;
            ghidra.app.cmd.function.CreateFunctionCmd.fixupFunctionBody(program, function, TaskMonitor.DUMMY);
            functions.add(hex(entry));
        }
        int decoded = 0;
        for (Instruction instruction : program.getListing().getInstructions(range, true)) decoded++;
        if (decoded == 0) throw new Failure(400, "no instruction decodes at " + hex(start) + " as " + bits + "-bit code");
        why(start, body);

        JsonObject answer = identity();
        answer.addProperty("start", hex(start));
        answer.addProperty("end", hex(end));
        answer.addProperty("bits", bits);
        answer.addProperty("instructions", decoded);
        answer.add("functions", functions);
        return answer;
    }

    /**
     * A name for a constant an instruction holds — an I/O port, a register
     * index, a magic value — as a Ghidra equate on that operand, which the
     * listing and the decompiler show instead of the number. `value` picks
     * the operand when `operand` is not given. An empty `name` removes the
     * equate there. A name already standing for another value is refused:
     * one name, one value.
     *
     * With `enum`, the name is a member of that enum — made in the program,
     * or brought from the shared review archive, when the program has none —
     * and `comment` is the member's: what the name stands for and where it
     * comes from, which the artifact carries to the reader. A member another
     * review commented keeps that comment unless a new one is given. Without
     * `enum`, a name the program's enums already hold is that member.
     */
    private JsonObject setEquate(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        Instruction instruction = program.getListing().getInstructionAt(at);
        if (instruction == null) throw new Failure(404, "no instruction at " + hex(at));
        String name = string(body, "name", "");
        if (!name.isEmpty() && !name.matches("[A-Za-z_][A-Za-z0-9_]*")) {
            throw new Failure(400, name + " is not a C identifier");
        }
        String enumName = string(body, "enum", null);
        if (enumName != null && !enumName.matches("[A-Za-z_][A-Za-z0-9_]*")) {
            throw new Failure(400, enumName + " is not a C identifier");
        }
        String comment = string(body, "comment", null);
        String enumComment = string(body, "enum_comment", null);
        String valueText = string(body, "value", null);
        Long value = null;
        if (valueText != null) {
            try {
                value = valueText.startsWith("0x") || valueText.startsWith("0X")
                    ? Long.parseUnsignedLong(valueText.substring(2), 16) : Long.parseLong(valueText);
            } catch (NumberFormatException error) {
                throw new Failure(400, valueText + " is not a number");
            }
        }
        int operand = integer(body, "operand", -1);

        // The operand and its scalar: the one asked for, or the one holding the value.
        ghidra.program.model.scalar.Scalar scalar = null;
        for (int index = 0; index < instruction.getNumOperands() && scalar == null; index++) {
            if (operand >= 0 && index != operand) continue;
            for (Object object : instruction.getOpObjects(index)) {
                if (!(object instanceof ghidra.program.model.scalar.Scalar candidate)) continue;
                if (value == null || candidate.getUnsignedValue() == value || candidate.getSignedValue() == value) {
                    scalar = candidate;
                    operand = index;
                    break;
                }
            }
        }
        if (scalar == null) {
            throw new Failure(409, "no operand of `" + instruction + "` at " + hex(at) + " holds "
                              + (value == null ? "a constant" : valueText));
        }
        long held = scalar.getUnsignedValue();
        long signed = scalar.getSignedValue();

        ghidra.program.model.symbol.EquateTable table = program.getEquateTable();
        JsonObject answer = identity();
        answer.addProperty("address", hex(at));
        answer.addProperty("operand", operand);
        answer.addProperty("value", "0x" + Long.toHexString(held).toUpperCase());
        if (name.isEmpty()) {
            dropEquates(table, at, operand);
            answer.addProperty("removed", true);
            return answer;
        }

        // A name the program's enums already hold is that member.
        ghidra.program.model.data.Enum owner = null;
        if (enumName != null) {
            owner = enumFor(enumName, held);
        } else {
            for (DataType type : allTypes()) {
                if (type instanceof ghidra.program.model.data.Enum values && values.contains(name)) {
                    owner = values;
                    break;
                }
            }
        }
        ghidra.program.model.symbol.Equate equate;
        if (owner != null) {
            long member = member(owner, name, held, signed, comment);
            if (enumComment != null) owner.setDescription(enumComment.isBlank() ? null : enumComment);
            Harvest.recordType(program, owner.getName(), ExportCode.typeC(owner));
            String formatted = ghidra.program.database.symbol.EquateManager
                .formatNameForEquate(owner.getUniversalID(), member);
            dropEquates(table, at, operand);
            equate = table.getEquate(formatted);
            if (equate == null) equate = table.createEquate(formatted, member);
            // The same name given before without its enum moves to the member.
            ghidra.program.model.symbol.Equate plain = table.getEquate(name);
            if (plain != null) {
                for (ghidra.program.model.symbol.EquateReference reference : plain.getReferences()) {
                    equate.addReference(reference.getAddress(), reference.getOpIndex());
                }
                table.removeEquate(name);
            }
            answer.addProperty("enum", owner.getName());
            String kept = owner.getComment(name);
            if (kept != null && !kept.isEmpty()) answer.addProperty("comment", kept);
        } else {
            if (comment != null) throw new Failure(400, "a comment is a member's: name the enum");
            equate = table.getEquate(name);
            if (equate != null && equate.getValue() != held && equate.getValue() != signed) {
                throw new Failure(409, name + " already stands for 0x" + Long.toHexString(equate.getValue()).toUpperCase());
            }
            dropEquates(table, at, operand);
            if (equate == null) equate = table.createEquate(name, held);
        }
        equate.addReference(at, operand);
        answer.addProperty("name", equate.getDisplayName());
        answer.addProperty("references", equate.getReferenceCount());
        return answer;
    }

    /** Removes whatever equate names the operand, and an equate it leaves unused. */
    private static void dropEquates(ghidra.program.model.symbol.EquateTable table, Address at, int operand)
            throws Exception {
        for (ghidra.program.model.symbol.Equate other : table.getEquates(at, operand)) {
            other.removeReference(at, operand);
            if (other.getReferenceCount() == 0) table.removeEquate(other.getName());
        }
    }

    private java.util.List<DataType> allTypes() {
        java.util.List<DataType> all = new java.util.ArrayList<>();
        program.getDataTypeManager().getAllDataTypes(all);
        return all;
    }

    /**
     * The program's enum of that name; else the shared archive's, brought in;
     * else a new one in /ByteRipper, four bytes wide, or eight for a value
     * that needs them.
     */
    private ghidra.program.model.data.Enum enumFor(String name, long held) throws Exception {
        ghidra.program.model.data.DataTypeManager manager = program.getDataTypeManager();
        DataType found = find(manager, name);
        if (found == null && reviewArchive != null) {
            DataType shared = find(reviewArchive, name);
            if (shared instanceof ghidra.program.model.data.Enum) {
                found = manager.resolve(shared, DataTypeConflictHandler.DEFAULT_HANDLER);
            }
        }
        if (found == null) {
            int size = held > 0xFFFFFFFFL ? 8 : 4;
            found = manager.resolve(new ghidra.program.model.data.EnumDataType(
                new ghidra.program.model.data.CategoryPath("/ByteRipper"), name, size, manager),
                DataTypeConflictHandler.DEFAULT_HANDLER);
        }
        if (!(found instanceof ghidra.program.model.data.Enum values)) {
            throw new Failure(409, name + " is a " + TypeText.kind(found) + ", not an enum");
        }
        return values;
    }

    /**
     * Makes `name` a member of `owner` for the value the operand holds, or
     * checks the member that is there; answers the member's value. A member
     * the shared archive's enum of the same name holds brings its comment.
     * One value, one name in an enum: an equate shows the first name of its
     * value, so a second would show as the first.
     */
    private long member(ghidra.program.model.data.Enum owner, String name, long held, long signed,
                        String comment) throws Exception {
        if (owner.contains(name)) {
            long member = owner.getValue(name);
            if (member != held && member != signed) {
                throw new Failure(409, owner.getName() + "." + name + " is 0x"
                                  + Long.toHexString(member).toUpperCase() + ", not 0x" + Long.toHexString(held).toUpperCase());
            }
            if (comment != null && !comment.equals(owner.getComment(name))) {
                owner.remove(name);
                owner.add(name, member, comment);
            }
            return member;
        }
        long member = held;
        if (owner.getLength() < 8 && held > 0xFFFFFFFFL) {
            if (signed >= Integer.MIN_VALUE && signed < 0) member = signed;
            else throw new Failure(409, owner.getName() + " is " + owner.getLength() + " bytes wide; 0x"
                                   + Long.toHexString(held).toUpperCase() + " does not fit");
        }
        if (owner.contains(member)) {
            throw new Failure(409, owner.getName() + " already names 0x" + Long.toHexString(held).toUpperCase()
                              + " " + owner.getName(member) + "; one value has one name in an enum");
        }
        String text = comment;
        if (text == null && reviewArchive != null
                && find(reviewArchive, owner.getName()) instanceof ghidra.program.model.data.Enum shared
                && shared.contains(name) && shared.getValue(name) == member) {
            text = shared.getComment(name);
        }
        owner.add(name, member, text == null ? "" : text);
        return member;
    }

    /** Who made a name and why, beside the reason ApplyUefi gives its own. */
    private void why(Address address, JsonObject body) throws Exception {
        String reason = string(body, "reason", null);
        String by = string(body, "by", "agent");
        if (!by.equals("agent") && !by.equals("person")) throw new Failure(400, "by is agent or person");
        StringPropertyMap reasons = propertyMap(Harvest.REASON);
        if (reason != null) reasons.add(address, reason); else reasons.remove(address);
        propertyMap(Harvest.BY).add(address, by);
    }

    private StringPropertyMap propertyMap(String name) throws Exception {
        StringPropertyMap map = program.getUsrPropertyManager().getStringPropertyMap(name);
        return map != null ? map : program.getUsrPropertyManager().createStringPropertyMap(name);
    }

    /**
     * A parameter (by ordinal, or by storage) or a local (by storage and, for
     * a register, its first use), named and perhaps typed through the
     * decompiler, which commits it to the program. Ghidra's own names for
     * unnamed locals renumber, so they are never accepted as an address.
     */
    private JsonObject renameVariable(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "function"));
        String name = string(body, "name", null);
        String storage = string(body, "storage", null);
        String firstUse = string(body, "first_use", null);
        Integer ordinal = body.has("ordinal") && !body.get("ordinal").isJsonNull() ? body.get("ordinal").getAsInt() : null;
        if (storage == null && ordinal == null) throw new Failure(400, "name the variable by storage (and first_use) or ordinal");
        DataType type = body.has("type") && !body.get("type").isJsonNull() ? type(body.get("type").getAsString()) : null;
        if (name == null && type == null) throw new Failure(400, "give a name, a type, or both");
        // Ghidra would sanitize an empty or odd name into one of its own
        // (`local_RAX_-1`), so a name that is not a C identifier is refused.
        if (name != null && !name.matches("[A-Za-z_][A-Za-z0-9_]*")) {
            throw new Failure(400, "\"" + name + "\" is not a C identifier: leave `name` out to set only the type");
        }
        DecompileResults results = decompile(function);
        HighFunction high = results == null ? null : results.getHighFunction();
        if (high == null) throw new Failure(500, "the function does not decompile");
        HighSymbol match = null;
        Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
        while (symbols.hasNext()) {
            HighSymbol symbol = symbols.next();
            if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
            boolean fits;
            if (ordinal != null) {
                fits = symbol.isParameter() && symbol.getCategoryIndex() == ordinal;
            } else {
                // A first use, when given, has to match whatever the variable is:
                // a parameter shares its register with locals of the body.
                fits = symbol.getStorage().toString().equals(storage)
                    && (firstUse == null
                        || (symbol.getPCAddress() != null && hex(symbol.getPCAddress()).equalsIgnoreCase(firstUse)));
            }
            if (!fits) continue;
            if (match != null) throw new Failure(409, "several variables are stored in " + storage + "; give first_use");
            match = symbol;
        }
        if (match == null) {
            // A variable the decompiler no longer shows — left behind by a
            // retyping — still sits in the function's table and holds its
            // name. The refusal of a rename names it; the table is where the
            // rename of it lands, so the name can be freed.
            ghidra.program.model.listing.Variable stale = null;
            if (storage != null) {
                for (ghidra.program.model.listing.Variable variable : function.getLocalVariables()) {
                    if (variable.getVariableStorage().toString().equals(storage)) { stale = variable; break; }
                }
                if (stale == null) {
                    for (Parameter parameter : function.getParameters()) {
                        if (parameter.getVariableStorage().toString().equals(storage)) { stale = parameter; break; }
                    }
                }
            }
            if (stale == null) throw new Failure(404, "no such variable in " + function.getName());
            try {
                if (name != null) stale.setName(name, SourceType.USER_DEFINED);
                if (type != null) stale.setDataType(type, SourceType.USER_DEFINED);
            } catch (Exception error) {
                throw new Failure(400, error.getMessage() + holderOf(name != null ? name : stale.getName(), function));
            }
            decompiled.remove(function.getEntryPoint());
            JsonObject answer = identity();
            answer.addProperty("function", hex(function.getEntryPoint()));
            answer.addProperty("name", stale.getName());
            answer.addProperty("storage", stale.getVariableStorage().toString());
            answer.addProperty("first_use", (String) null);
            answer.addProperty("parameter", stale instanceof Parameter);
            answer.addProperty("stale", true);
            return answer;
        }
        String applied = name != null ? name : match.getName();
        try {
            HighFunctionDBUtil.updateDBVariable(match, applied, type, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage() + holderOf(applied, function));
        }
        // The storage as it is now: a decompiler temporary becomes HASH:… once
        // it is named, and that is what names it from here on.
        decompiled.remove(function.getEntryPoint());
        JsonObject answer = identity();
        answer.addProperty("function", hex(function.getEntryPoint()));
        answer.addProperty("name", applied);
        HighFunction after = decompile(function).getHighFunction();
        if (after != null) {
            Iterator<HighSymbol> now = after.getLocalSymbolMap().getSymbols();
            while (now.hasNext()) {
                HighSymbol symbol = now.next();
                if (!symbol.getName().equals(applied)) continue;
                answer.addProperty("storage", symbol.getStorage().toString());
                Address first = symbol.getPCAddress();
                answer.addProperty("first_use", first == null ? null : hex(first));
                answer.addProperty("parameter", symbol.isParameter());
            }
        }
        return answer;
    }

    private JsonObject setSignature(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        String text = edk2(required(body, "signature"));
        // Ghidra's signature parser misreads the pointers of the return type
        // when the function's name is already a symbol of the program (`T *`
        // came back as `T`, or as `T **`). The text is parsed under a name
        // nothing has, and the real one is set afterwards.
        java.util.regex.Matcher named = java.util.regex.Pattern
            .compile("([A-Za-z_][A-Za-z0-9_]*)\\s*\\(").matcher(text);
        if (!named.find()) throw new Failure(400, "the signature names no function");
        String name = named.group(1);
        String parsed = text.substring(0, named.start(1)) + " __byteripper_signature"
                        + text.substring(named.end(1));
        importTypes(parsed);
        FunctionDefinitionDataType signature;
        try {
            signature = CParserUtils.parseSignature((ghidra.app.services.DataTypeManagerService) null,
                                                    program, parsed, false);
        } catch (Exception error) {
            throw new Failure(400, "the signature does not parse: " + error.getMessage());
        }
        if (signature == null) throw new Failure(400, "the signature does not parse");
        signature.setName(name);
        ApplyFunctionSignatureCmd command =
            new ApplyFunctionSignatureCmd(function.getEntryPoint(), signature, SourceType.USER_DEFINED);
        if (!command.applyTo(program)) throw new Failure(400, command.getStatusMsg());
        // The command renames only a function Ghidra named; a signature's name
        // is the reviewer's either way.
        if (!function.getName().equals(name)) {
            try {
                function.setName(name, SourceType.USER_DEFINED);
            } catch (Exception error) {
                throw new Failure(409, error.getMessage());
            }
        }
        if (body.has("storage") || body.has("return_storage")) applyStorage(function, body);
        if (!function.getName().equals(signature.getName()) || function.getSymbol().getSource() == SourceType.USER_DEFINED) {
            why(function.getEntryPoint(), body);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("signature", function.getPrototypeString(false, false));
        if (function.hasCustomVariableStorage()) {
            JsonArray storage = new JsonArray();
            for (Parameter parameter : function.getParameters()) storage.add(parameter.getVariableStorage().toString());
            answer.add("storage", storage);
            answer.addProperty("return_storage", function.getReturn().getVariableStorage().toString());
        }
        return answer;
    }

    /**
     * Where each parameter and the result really are, for a function no
     * calling convention describes: a linker's clone that takes its argument
     * in EDX, or hands its result back through a pointer in ECX. `storage`
     * has one entry per parameter of the signature just applied, written as
     * `ghidra_function` lists storage — `EDX:4`, `Stack[0x4]:4`, `EDX:4,EAX:4`
     * for a value split over two; `return_storage` the result's, `EAX:4` by
     * default as the convention put it.
     */
    private void applyStorage(Function function, JsonObject body) throws Exception {
        Parameter[] current = function.getParameters();
        java.util.List<ghidra.program.model.listing.Variable> parameters = new java.util.ArrayList<>();
        JsonArray storage = body.has("storage") && body.get("storage").isJsonArray()
            ? body.getAsJsonArray("storage") : null;
        if (storage != null && storage.size() != current.length) {
            throw new Failure(400, "storage names " + storage.size() + " places for " + current.length
                + " parameters of the signature");
        }
        for (int index = 0; index < current.length; index++) {
            ghidra.program.model.listing.VariableStorage place = storage == null
                ? current[index].getVariableStorage()
                : storage(storage.get(index).getAsString(), current[index].getLength());
            parameters.add(new ghidra.program.model.listing.ParameterImpl(
                current[index].getName(), current[index].getDataType(), place, program, SourceType.USER_DEFINED));
        }
        ghidra.program.model.listing.Parameter result = function.getReturn();
        ghidra.program.model.listing.VariableStorage resultPlace = body.has("return_storage")
            ? storage(body.get("return_storage").getAsString(), result.getLength())
            : result.getVariableStorage();
        ghidra.program.model.listing.ReturnParameterImpl returned =
            new ghidra.program.model.listing.ReturnParameterImpl(result.getDataType(), resultPlace, program);
        try {
            function.updateFunction(function.getCallingConventionName(), returned, parameters,
                Function.FunctionUpdateType.CUSTOM_STORAGE, true, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, "the storage does not fit: " + error.getMessage());
        }
    }

    /** `EDX:4`, `Stack[0x4]:4`, `EDX:4,EAX:4` (high part first), or `void`. */
    private ghidra.program.model.listing.VariableStorage storage(String text, int length) throws Exception {
        text = text.trim();
        if (text.isEmpty() || text.equalsIgnoreCase("void")) return ghidra.program.model.listing.VariableStorage.VOID_STORAGE;
        java.util.List<ghidra.program.model.pcode.Varnode> pieces = new java.util.ArrayList<>();
        int total = 0;
        for (String piece : text.split(",")) {
            piece = piece.trim();
            java.util.regex.Matcher stack = java.util.regex.Pattern
                .compile("(?i)stack\\[(-?)(0x[0-9a-f]+|\\d+)\\](?::(\\d+))?").matcher(piece);
            if (stack.matches()) {
                long offset = Long.decode(stack.group(2));
                if (!stack.group(1).isEmpty()) offset = -offset;
                int size = stack.group(3) != null ? Integer.parseInt(stack.group(3)) : length;
                pieces.add(new ghidra.program.model.pcode.Varnode(
                    program.getAddressFactory().getStackSpace().getAddress(offset), size));
                total += size;
                continue;
            }
            String[] parts = piece.split(":");
            ghidra.program.model.lang.Register register = program.getRegister(parts[0].trim());
            if (register == null) throw new Failure(400, "no register or stack place " + piece);
            int size = parts.length > 1 ? Integer.parseInt(parts[1].trim()) : register.getMinimumByteSize();
            pieces.add(new ghidra.program.model.pcode.Varnode(register.getAddress(), size));
            total += size;
        }
        if (length > 0 && total != length) {
            throw new Failure(400, text + " holds " + total + " bytes for a value of " + length);
        }
        return new ghidra.program.model.listing.VariableStorage(program,
            pieces.toArray(new ghidra.program.model.pcode.Varnode[0]));
    }

    private JsonObject setComment(JsonObject body) throws Exception {
        Address address = address(required(body, "address"));
        CommentType kind;
        try {
            kind = CommentType.valueOf(string(body, "kind", "pre").toUpperCase());
        } catch (IllegalArgumentException error) {
            throw new Failure(400, "kind is pre, post, eol, plate or repeatable");
        }
        CodeUnit unit = program.getListing().getCodeUnitAt(address);
        if (unit == null) throw new Failure(404, "nothing starts at " + hex(address));
        String text = string(body, "text", null);
        unit.setComment(kind, text == null || text.isEmpty() ? null : text);
        JsonObject answer = identity();
        answer.addProperty("address", hex(address));
        answer.addProperty("kind", kind.name().toLowerCase());
        return answer;
    }

    private JsonObject setData(JsonObject body) throws Exception {
        Address address = address(required(body, "address"));
        if (body.has("type") && !body.get("type").isJsonNull()) {
            DataType type = type(body.get("type").getAsString());
            DataUtilities.createData(program, address, type, -1,
                                     DataUtilities.ClearDataMode.CLEAR_ALL_CONFLICT_DATA);
        }
        String name = string(body, "name", null);
        if (name != null) {
            Symbol primary = program.getSymbolTable().getPrimarySymbol(address);
            try {
                if (primary != null && !primary.isDynamic()) primary.setName(name, SourceType.USER_DEFINED);
                else program.getSymbolTable().createLabel(address, name, SourceType.USER_DEFINED);
            } catch (Exception error) {
                throw new Failure(400, error.getMessage());
            }
        }
        JsonObject answer = identity();
        answer.addProperty("address", hex(address));
        Data datum = program.getListing().getDefinedDataAt(address);
        if (datum != null) answer.addProperty("type", datum.getDataType().getDisplayName());
        return answer;
    }

    /**
     * `typedef enum { … } NAME;` with the tag `_NAME` written in. Ghidra's C
     * parser names an anonymous enum by where it starts in the text, so two
     * of them, each first in its own call, are the same type to the program:
     * the second replaced the first's values, and the decompiler wrote an
     * EFI_STATUS as DEBUG_* flags. A structure or union is tagged the same.
     */
    static String tagAnonymous(String c) {
        java.util.regex.Matcher open = java.util.regex.Pattern
            .compile("\\btypedef\\s+(struct|union|enum)\\s*\\{").matcher(c);
        java.util.regex.Pattern name = java.util.regex.Pattern.compile("\\s*([A-Za-z_][A-Za-z0-9_]*)");
        StringBuilder out = new StringBuilder();
        int from = 0;
        while (open.find(from)) {
            int brace = open.end() - 1;
            int depth = 0, close = -1;
            for (int i = brace; i < c.length() && close < 0; i++) {
                if (c.charAt(i) == '{') depth++;
                else if (c.charAt(i) == '}' && --depth == 0) close = i;
            }
            if (close < 0) break;
            java.util.regex.Matcher named = name.matcher(c).region(close + 1, c.length());
            out.append(c, from, brace);
            if (named.lookingAt()) out.append('_').append(named.group(1)).append(' ');
            out.append(c, brace, close + 1);
            from = close + 1;
        }
        out.append(c.substring(from));
        return out.toString();
    }

    /**
     * A structure, union, enum or typedef from C, into the program; or, with
     * `name` and no C, a type the program holds. Either way `description`
     * says what the type is, and `comments` gives a field or an enum member
     * its comment — what it holds, and where that is known from — which the
     * artifact carries to the reader. An empty comment removes one.
     */
    private JsonObject addType(JsonObject body) throws Exception {
        // A type a review no longer wants — a probe, a mistake — goes from the
        // program and from the review's list, so the next publish cannot carry
        // it. Archives are read-only here and are refused by the manager check.
        if (body.has("delete") && body.get("delete").getAsBoolean()) {
            String name = required(body, "name");
            DataType found = find(program.getDataTypeManager(), name.trim());
            if (found == null || found.getDataTypeManager() != program.getDataTypeManager()) {
                throw new Failure(404, "no type " + name + " of this program to delete; archives are read-only here");
            }
            try {
                if (!program.getDataTypeManager().remove(found)) {
                    throw new Failure(409, found.getName() + " is still used and cannot be deleted");
                }
            } catch (Failure failure) {
                throw failure;
            } catch (Exception error) {
                throw new Failure(409, error.getMessage());
            }
            Harvest.forgetType(program, found.getName());
            JsonObject answer = identity();
            answer.addProperty("deleted", found.getName());
            return answer;
        }
        String c = string(body, "c", null);
        DataType resolved;
        int commentsKept = 0;
        boolean unchanged = false;
        if (c != null) {
            // Read before the parser touches the manager: CParser adds a type
            // as it parses it, so by the time it returns, the old fields'
            // comments are gone and the old type is no longer what the manager
            // holds.
            java.util.TreeMap<String, DataType> previous = namedTypes(c);
            java.util.Map<String, java.util.Map<String, String>> kept = keptComments(previous);
            java.util.Map<String, String> keptDescriptions = keptDescriptions(previous);
            // The fields may name what only an archive holds — `CHAR8`, a PI
            // structure, another review's type — as a signature may.
            importTypes(c);
            DataType parsed;
            try {
                parsed = new CParser(program.getDataTypeManager(), true, null).parse(tagAnonymous(c));
            } catch (Exception error) {
                throw new Failure(400, "the C does not parse: " + error.getMessage());
            }
            if (parsed == null) throw new Failure(400, "the C declares no type");
            // The C the program already holds: the answer says so, and the
            // fields' comments are still put back — the parser replaced the
            // type on its way through, comments and all.
            unchanged = declaredSame(previous, parsed);
            // A type defined again — a corrected layout — replaces the one in
            // the program, and the parsed C carries no comments: the fields'
            // old comments are put back by name, so a correction is one call,
            // not two. A field the new C dropped keeps nothing. Comments of a
            // type the C only mentions are left where they are.
            java.util.Set<String> declared = new java.util.HashSet<>();
            declared.add(parsed.getName());
            if (parsed instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null) {
                declared.add(def.getBaseDataType().getName());
            }
            kept.keySet().retainAll(declared);
            resolved = program.getDataTypeManager().resolve(parsed, DataTypeConflictHandler.REPLACE_HANDLER);
            commentsKept = restoreComments(resolved, kept);
            restoreDescriptions(resolved, keptDescriptions);
        } else {
            String name = required(body, "name");
            importTypes(name);
            resolved = find(program.getDataTypeManager(), name.trim());
            if (resolved == null) throw new Failure(404, "no type " + name + " in the program or its archives");
        }
        JsonObject answer = identity();
        if (body.has("description") && !body.get("description").isJsonNull()) {
            String description = body.get("description").getAsString();
            // A typedef keeps no description of its own in Ghidra: the type it names does.
            DataType described = resolved instanceof ghidra.program.model.data.TypeDef def
                ? def.getBaseDataType() : resolved;
            described.setDescription(description.isBlank() ? null : description);
        }
        if (body.has("comments") && body.get("comments").isJsonObject()) {
            JsonObject comments = body.getAsJsonObject("comments");
            DataType base = resolved instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : resolved;
            java.util.List<String> missing = new java.util.ArrayList<>();
            for (String member : comments.keySet()) {
                String text = comments.get(member).isJsonNull() ? "" : comments.get(member).getAsString();
                if (!comment(base, member, text)) missing.add(member);
            }
            if (!missing.isEmpty()) {
                throw new Failure(404, resolved.getName() + " has no " + String.join(", ", missing));
            }
        }
        // The canonical C, not the text the caller sent: two equivalent
        // definitions must leave the review document byte-identical, or a
        // redefinition for a check reads as a new revision.
        Harvest.recordType(program, resolved.getName(), ExportCode.typeC(resolved));
        answer.addProperty("name", resolved.getName());
        answer.addProperty("path", resolved.getPathName());
        answer.addProperty("size", resolved.getLength());
        answer.addProperty("c", ExportCode.typeC(resolved));
        // Always present, zero included: a reader must be able to tell "nothing
        // came back" from "this build has no such field".
        answer.addProperty("comments_kept", commentsKept);
        answer.addProperty("unchanged", unchanged);
        return answer;
    }

    /**
     * The program's types a C names, by name, read before the C is parsed: the
     * parser replaces a type it defines as it goes, so a lookup afterwards
     * finds the new one.
     */
    private java.util.TreeMap<String, DataType> namedTypes(String c) {
        java.util.TreeMap<String, DataType> found = new java.util.TreeMap<>();
        java.util.regex.Matcher words = java.util.regex.Pattern.compile("[A-Za-z_][A-Za-z0-9_]*").matcher(c);
        while (words.find()) {
            DataType existing = find(program.getDataTypeManager(), words.group());
            if (existing == null || existing.getDataTypeManager() != program.getDataTypeManager()) continue;
            // A copy, not the type: resolve changes a replaced type in place,
            // so a reference taken here would show the new layout when the C
            // is compared after parsing.
            found.putIfAbsent(existing.getName(), existing.copy(null));
            if (existing instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null
                && def.getBaseDataType().getDataTypeManager() == program.getDataTypeManager()) {
                found.putIfAbsent(def.getBaseDataType().getName(), def.getBaseDataType().copy(null));
            }
        }
        return found;
    }

    /**
     * The comments of the types a C names, by type and field. Comments sit on
     * the structure or enum a typedef names, and a C names both: one entry per
     * such type, or a field would be counted once per spelling.
     */
    private java.util.Map<String, java.util.Map<String, String>> keptComments(java.util.TreeMap<String, DataType> named) {
        java.util.Map<String, java.util.Map<String, String>> kept = new java.util.LinkedHashMap<>();
        for (DataType type : named.values()) {
            DataType base = type instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null
                ? def.getBaseDataType() : type;
            java.util.Map<String, String> comments = fieldComments(base);
            if (!comments.isEmpty()) kept.putIfAbsent(base.getName(), comments);
        }
        return kept;
    }

    /**
     * The descriptions of the types a C names, by name. A type defined again
     * with the same C keeps its description the way it keeps its fields'
     * comments: the parsed C carries neither.
     */
    private java.util.Map<String, String> keptDescriptions(java.util.TreeMap<String, DataType> named) {
        java.util.Map<String, String> kept = new java.util.TreeMap<>();
        for (DataType type : named.values()) {
            DataType base = type instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null
                ? def.getBaseDataType() : type;
            String description = base.getDescription();
            if (description != null && !description.isEmpty()) kept.putIfAbsent(base.getName(), description);
        }
        return kept;
    }

    /** Puts a kept description back, unless the call gives one of its own. */
    private static void restoreDescriptions(DataType resolved, java.util.Map<String, String> kept) {
        if (resolved == null) return;
        DataType base = resolved instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null
            ? def.getBaseDataType() : resolved;
        String description = kept.get(base.getName());
        if (description == null) return;
        String now = base.getDescription();
        if (now != null && !now.isEmpty()) return;
        base.setDescription(description);
    }

    /** Do the types a C declares match the ones the program held before it was parsed? */
    private static boolean declaredSame(java.util.TreeMap<String, DataType> previous, DataType parsed) {
        DataType named = previous.get(parsed.getName());
        if (named == null || !sameShape(named, parsed)) return false;
        if (!(parsed instanceof ghidra.program.model.data.TypeDef def) || def.getBaseDataType() == null) return true;
        DataType base = def.getBaseDataType();
        DataType before = previous.get(base.getName());
        return before != null && sameShape(before, base);
    }

    /**
     * The same type in shape: fields, names and offsets. Comments and the
     * description are not the C's, so a type whose comments a review has set
     * still matches the C that declares it.
     */
    private static boolean sameShape(DataType a, DataType b) {
        DataType left = a instanceof ghidra.program.model.data.TypeDef defA && defA.getBaseDataType() != null
            ? defA.getBaseDataType() : a;
        DataType right = b instanceof ghidra.program.model.data.TypeDef defB && defB.getBaseDataType() != null
            ? defB.getBaseDataType() : b;
        if (left instanceof ghidra.program.model.data.Composite mine
            && right instanceof ghidra.program.model.data.Composite theirs) {
            return uncommented(mine).isEquivalent(uncommented(theirs));
        }
        return left.isEquivalent(right);
    }

    /** The comments a structure's fields, or an enum's members, hold, by name. */
    private static java.util.Map<String, String> fieldComments(DataType type) {
        DataType base = type instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : type;
        java.util.Map<String, String> comments = new java.util.LinkedHashMap<>();
        if (base instanceof ghidra.program.model.data.Composite composite) {
            for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
                String comment = component.getComment();
                if (comment != null && !comment.isEmpty()) comments.put(ExportCode.fieldName(component), comment);
            }
        } else if (base instanceof ghidra.program.model.data.Enum values) {
            for (String member : values.getNames()) {
                String comment = values.getComment(member);
                if (comment != null && !comment.isEmpty()) comments.put(member, comment);
            }
        }
        return comments;
    }

    /** Puts kept comments back on the types that replaced them; answers how many landed. */
    private int restoreComments(DataType resolved, java.util.Map<String, java.util.Map<String, String>> kept) {
        int restored = 0;
        for (java.util.Map.Entry<String, java.util.Map<String, String>> entry : kept.entrySet()) {
            DataType type = find(program.getDataTypeManager(), entry.getKey());
            if (type == null || type.getDataTypeManager() != program.getDataTypeManager()) continue;
            DataType base = type instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : type;
            for (java.util.Map.Entry<String, String> comment : entry.getValue().entrySet()) {
                if (comment(base, comment.getKey(), comment.getValue())) restored++;
            }
        }
        return restored;
    }

    /**
     * What holds a name in a function's namespace, for a rename Ghidra refused
     * because the name was taken: the refusal alone names neither address nor
     * kind, and a symbol no decompiled variable shows is otherwise invisible.
     */
    private String holderOf(String name, Function function) {
        if (name == null) return "";
        StringBuilder holders = new StringBuilder();
        java.util.Iterator<ghidra.program.model.symbol.Symbol> symbols =
            program.getSymbolTable().getSymbols(name, function).iterator();
        while (symbols.hasNext()) {
            ghidra.program.model.symbol.Symbol symbol = symbols.next();
            holders.append(holders.length() == 0 ? " — the name is already held by " : "; ")
                   .append(symbol.getSymbolType().toString().toLowerCase(java.util.Locale.ROOT))
                   .append(" at ").append(hex(symbol.getAddress()));
            // The address alone is the storage space's, which no call takes;
            // the variable's storage is what to rename it by.
            if (symbol.getObject() instanceof ghidra.program.model.listing.Variable variable) {
                holders.append(" (storage ").append(variable.getVariableStorage()).append(")");
            }
        }
        return holders.toString();
    }

    /** A field's or an enum member's comment; false when the type has no such member. */
    private static boolean comment(DataType type, String member, String text) {
        String value = text.isBlank() ? null : text;
        if (type instanceof ghidra.program.model.data.Composite composite) {
            for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
                if (member.equals(ExportCode.fieldName(component))) {
                    component.setComment(value);
                    return true;
                }
            }
            return false;
        }
        if (type instanceof ghidra.program.model.data.Enum values && values.contains(member)) {
            long number = values.getValue(member);
            values.remove(member);
            values.add(member, number, value == null ? "" : value);
            return true;
        }
        return false;
    }

    /**
     * A type by name as the program holds it, as the shared review archive
     * holds it now — read afresh, since another owner may have published
     * into it since this one opened — and as EDK2's archive holds it, each
     * as C and as fields with their offsets: what a review needs to bring
     * its own definition in line with the one `publish` reported.
     */
    private JsonObject readType(Map<String, String> query) throws Exception {
        String name = query.get("name");
        if (name == null || name.isBlank()) throw new Failure(400, "name the type: ?name=");
        name = name.trim();
        JsonObject answer = identity();
        answer.addProperty("name", name);
        // A typedef and the structure it names differ by one underscore, and a
        // reader who has the tag asks by it: `_NAME` finds what `NAME` names
        // and the other way round.
        String alternate = name.startsWith("_") ? name.substring(1) : "_" + name;
        DataType here = findAny(program.getDataTypeManager(), name, alternate);
        answer.add("program", TypeText.describe(here));
        DataType inShared = null;
        if (reviewTypes != null && reviewTypes.isFile()) {
            File copy = File.createTempFile("review-types-", ".gdt");
            try {
                try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
                    Files.copy(reviewTypes.toPath(), copy.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
                FileDataTypeManager shared = FileDataTypeManager.openFileArchive(copy, false);
                try {
                    inShared = findAny(shared, name, alternate);
                    answer.add("shared", TypeText.describe(inShared));
                    if (here != null && inShared != null) answer.addProperty("same", inShared.isEquivalent(here));
                } finally {
                    shared.close();
                }
            } finally {
                copy.delete();
            }
        } else {
            answer.add("shared", com.google.gson.JsonNull.INSTANCE);
        }
        DataType inEdk2 = archive == null ? null : findAny(archive, name, alternate);
        answer.add("edk2", TypeText.describe(inEdk2));
        DataType anywhere = here != null ? here : inShared != null ? inShared : inEdk2;
        answer.addProperty("found", anywhere != null);
        if (anywhere != null) {
            if (!anywhere.getName().equals(name)) answer.addProperty("resolved", anywhere.getName());
        } else {
            // Nothing by either spelling: say so, and list what is close, so a
            // miss is not read as "the type is gone".
            answer.add("near", near(name));
        }
        return answer;
    }

    /** A type by its name or its tag; the first found, or null. */
    private static DataType findAny(ghidra.program.model.data.DataTypeManager manager, String name, String alternate) {
        DataType found = find(manager, name);
        return found != null ? found : find(manager, alternate);
    }

    /** The program's type names close to one that was not found — the tag's underscore aside. */
    private JsonArray near(String name) {
        String needle = (name.startsWith("_") ? name.substring(1) : name).toLowerCase(java.util.Locale.ROOT);
        JsonArray near = new JsonArray();
        Iterator<DataType> all = program.getDataTypeManager().getAllDataTypes();
        while (all.hasNext() && near.size() < 10) {
            DataType type = all.next();
            if (type instanceof ghidra.program.model.data.BuiltInDataType) continue;
            String plain = type.getName().startsWith("_") ? type.getName().substring(1) : type.getName();
            if (plain.toLowerCase(java.util.Locale.ROOT).contains(needle)) near.add(type.getName());
        }
        return near;
    }

    private static DataType find(ghidra.program.model.data.DataTypeManager manager, String name) {
        java.util.List<DataType> found = new java.util.ArrayList<>();
        manager.findDataTypes(name, found);
        return found.isEmpty() ? null : found.get(0);
    }

    /**
     * Brings into the program every type `text` names that the program does
     * not hold but the EDK2 archive does — `VOID`, a protocol, a PI table —
     * so a signature or a variable can be written the way EDK2 spells it.
     */
    private void importTypes(String text) {
        if (archive == null && reviewArchive == null) return;
        java.util.regex.Matcher words = java.util.regex.Pattern.compile("[A-Za-z_][A-Za-z0-9_]*").matcher(text);
        while (words.find()) {
            String word = words.group();
            java.util.List<DataType> here = new java.util.ArrayList<>();
            program.getDataTypeManager().findDataTypes(word, here);
            if (!here.isEmpty()) continue;
            // Another review's type first, then EDK2's.
            for (FileDataTypeManager source : new FileDataTypeManager[] {reviewArchive, archive}) {
                if (source == null) continue;
                java.util.List<DataType> there = new java.util.ArrayList<>();
                source.findDataTypes(word, there);
                if (!there.isEmpty()) {
                    program.getDataTypeManager().resolve(there.get(0), DataTypeConflictHandler.DEFAULT_HANDLER);
                    break;
                }
            }
        }
    }

    /**
     * EDK2's spelling without its macros, which are not types: `VOID` is
     * `void`, `CONST` is `const`, and `IN`, `OUT`, `OPTIONAL`, `EFIAPI` say
     * nothing a C parser reads.
     */
    static String edk2(String text) {
        return text.replaceAll("\\bVOID\\b", "void")
                   .replaceAll("\\bCONST\\b", "const")
                   .replaceAll("\\b(IN|OUT|OPTIONAL|EFIAPI)\\b", " ")
                   .replaceAll("\\s+", " ").trim();
    }

    private DataType type(String text) throws Failure {
        text = edk2(text);
        importTypes(text);
        try {
            DataType type = new DataTypeParser(program.getDataTypeManager(), program.getDataTypeManager(),
                                               null, DataTypeParser.AllowedDataTypes.ALL).parse(text);
            if (type == null) throw new Failure(400, "no type " + text);
            return type;
        } catch (Failure failure) {
            throw failure;
        } catch (Exception error) {
            throw new Failure(400, "no type " + text + ": " + error.getMessage());
        }
    }

    // MARK: - Program

    private Function functionAt(String text) throws Failure {
        Address address = address(text);
        Function function = program.getFunctionManager().getFunctionAt(address);
        if (function == null) function = program.getFunctionManager().getFunctionContaining(address);
        if (function == null) throw new Failure(404, "no function at " + text);
        return function;
    }

    private Address address(String text) throws Failure {
        String digits = text.startsWith("0x") || text.startsWith("0X") ? text.substring(2) : text;
        try {
            long offset = Long.parseUnsignedLong(digits, 16);
            return program.getAddressFactory().getDefaultAddressSpace().getAddress(offset);
        } catch (Exception error) {
            throw new Failure(400, text + " is not an address");
        }
    }

    /**
     * A function's decompilation, kept until the program changes: a rename
     * changes the C of the function and of every caller, so any change
     * empties the whole cache, and a function is decompiled again only when
     * it is read.
     */
    private DecompileResults decompile(Function function) {
        long now = program.getModificationNumber();
        if (now != decompiledAt) {
            decompiled.clear();
            decompiledAt = now;
        }
        return decompiled.computeIfAbsent(function.getEntryPoint(),
            entry -> decompiler.decompileFunction(function, 120, TaskMonitor.DUMMY));
    }

    private JsonObject reference(Reference reference) {
        JsonObject item = new JsonObject();
        item.addProperty("from", hex(reference.getFromAddress()));
        item.addProperty("to", hex(reference.getToAddress()));
        item.addProperty("type", reference.getReferenceType().getName());
        Function from = program.getFunctionManager().getFunctionContaining(reference.getFromAddress());
        if (from != null) item.addProperty("function", hex(from.getEntryPoint()));
        return item;
    }

    // MARK: - Plumbing

    private static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }

    private static String hexBytes(byte[] bytes) {
        StringBuilder builder = new StringBuilder();
        for (byte value : bytes) {
            if (builder.length() > 0) builder.append(' ');
            builder.append(String.format("%02X", value & 0xFF));
        }
        return builder.toString();
    }

    private static JsonObject body(HttpExchange exchange) throws Failure {
        try {
            String text = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            if (text.isBlank()) return new JsonObject();
            JsonElement element = JsonParser.parseString(text);
            if (!element.isJsonObject()) throw new Failure(400, "the body is not a JSON object");
            return element.getAsJsonObject();
        } catch (Failure failure) {
            throw failure;
        } catch (Exception error) {
            throw new Failure(400, "the body is not JSON: " + error.getMessage());
        }
    }

    private static String required(JsonObject body, String name) throws Failure {
        String value = string(body, name, null);
        if (value == null || value.isEmpty()) throw new Failure(400, name + " is required");
        return value;
    }

    private static String string(JsonObject body, String name, String fallback) {
        JsonElement value = body.get(name);
        return value == null || value.isJsonNull() ? fallback : value.getAsString();
    }

    private static int integer(JsonObject body, String name, int fallback) throws Failure {
        JsonElement value = body.get(name);
        if (value == null || value.isJsonNull()) return fallback;
        try {
            return value.getAsInt();
        } catch (Exception error) {
            throw new Failure(400, name + " is not a number");
        }
    }

    private static int integer(Map<String, String> query, String name, int fallback) throws Failure {
        String value = query.get(name);
        if (value == null) return fallback;
        try {
            return Math.max(0, Integer.parseInt(value));
        } catch (NumberFormatException error) {
            throw new Failure(400, name + " is not a number");
        }
    }

    private static Map<String, String> query(String raw) {
        Map<String, String> map = new HashMap<>();
        if (raw == null || raw.isEmpty()) return map;
        for (String pair : raw.split("&")) {
            String[] parts = pair.split("=", 2);
            map.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8),
                    parts.length > 1 ? URLDecoder.decode(parts[1], StandardCharsets.UTF_8) : "");
        }
        return map;
    }

    private void json(HttpExchange exchange, int status, JsonObject answer) throws Exception {
        byte[] bytes = (gson.toJson(answer) + "\n").getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream body = exchange.getResponseBody()) { body.write(bytes); }
    }

    private void error(HttpExchange exchange, int status, String message) {
        try {
            JsonObject answer = new JsonObject();
            answer.addProperty("error", message);
            json(exchange, status, answer);
        } catch (Exception ignored) {
            exchange.close();
        }
    }
}
