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
import ghidra.program.model.address.AddressRange;
import ghidra.program.model.address.AddressRangeImpl;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.address.AddressSetView;
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
import ghidra.program.model.mem.MemoryBlock;
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
    /** How far rollbacks have moved the program's number: see `modification()`. */
    private long rolledBack;
    /** See `writes()`: the file beside the project, what it held at open, the number then, what it holds now. */
    private File writesFile;
    private long writesCarried;
    private long modificationAtOpen;
    private File savedFile;
    private File lostFile;
    private long writesWritten;
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
        decompiler.setOptions(ExportCode.decompileOptions(program));
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
        if (recorded) saveProgram("baseline");
        ExportCode.analysisComments = Harvest.baselineComments(program);
        // From here a change counts; the count goes on from the last session's.
        writesFile = new File(options.get("project-dir"), "writes");
        writesCarried = readWrites();
        writesWritten = writesCarried;
        modificationAtOpen = program.getModificationNumber();
        lostFile = new File(options.get("project-dir"), "writes-lost");
        savedFile = new File(options.get("project-dir"), "writes-saved");
        noteLostWrites();

        int port = Integer.parseInt(options.getOrDefault("port", "0"));
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        // One thread: every call sees the program between two changes, never
        // in the middle of one.
        server.setExecutor(Executors.newSingleThreadExecutor());
        server.createContext("/", this::handle);
        server.start();
        Runtime.getRuntime().addShutdownHook(new Thread(this::close));
        for (String name : new String[] { "TERM", "INT", "HUP" }) {
            sun.misc.Signal.handle(new sun.misc.Signal(name), signal -> {
                System.out.println("OWNER SIGNAL " + signal.getName());
                closeAndExit(server);
            });
        }
        long idle = Long.parseLong(options.getOrDefault("idle", "0"));
        if (idle > 0) {
            Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(() -> {
                if (System.currentTimeMillis() - lastRequest > idle * 1000) {
                    System.out.println("OWNER IDLE");
                    closeAndExit(server);
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

    /**
     * Save first, exit after. Ghidra closes its files in a shutdown hook of its
     * own, and hooks run together: left to ours, the save lost that race about
     * every other time and the writes since the last save were gone. On the
     * server's thread, so it never lands in the middle of a change.
     */
    private void closeAndExit(HttpServer server) {
        server.getExecutor().execute(() -> {
            close();
            System.exit(0);
        });
    }

    /** Save what changed and let the program go: on stop, idle and a signal. */
    private synchronized void close() {
        try {
            if (program == null) return;
            if (program.isChanged()) saveProgram("owner");
            keepWrites();
            keepSaved();
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
                if (path.equals("/v1/gaps")) { json(exchange, 200, gaps(query)); return; }
                if (path.startsWith("/v1/function/")) { json(exchange, 200, function(path.substring(13), query)); return; }
                if (path.startsWith("/v1/disassembly/")) { json(exchange, 200, disassembly(path.substring(16), query)); return; }
                if (path.equals("/v1/xrefs")) { json(exchange, 200, xrefs(query)); return; }
                if (path.equals("/v1/data")) { json(exchange, 200, data(query, false)); return; }
                if (path.equals("/v1/strings")) { json(exchange, 200, data(query, true)); return; }
                if (path.equals("/v1/review")) { review(exchange); return; }
                if (path.equals("/v1/library")) { json(exchange, 200, library()); return; }
                if (path.equals("/v1/equates-on-memory")) { json(exchange, 200, equatesOnMemory(query)); return; }
                if (path.equals("/v1/stale-links")) { json(exchange, 200, staleLinks()); return; }
                if (path.equals("/v1/review/description")) { publishedDescription(exchange); return; }
                if (path.equals("/v1/description")) { json(exchange, 200, description(query)); return; }
                if (path.equals("/v1/type")) { json(exchange, 200, readType(query)); return; }
                if (path.equals("/v1/types")) { json(exchange, 200, types(query)); return; }
            } else if (method.equals("DELETE") && path.equals("/v1/lease")) {
                json(exchange, 200, release(exchange));
                return;
            } else if (method.equals("POST")) {
                if (path.equals("/v1/publish")) { publish(exchange); return; }
                if (path.equals("/v1/lease")) { lease(exchange, body(exchange)); return; }
                // The registry's reads take a body (the keys) and write nothing.
                if (path.equals("/v1/library/match")) { json(exchange, 200, libraryMatch(body(exchange))); return; }
                if (path.equals("/v1/library/compare")) { json(exchange, 200, libraryCompare(body(exchange))); return; }
                if (path.equals("/v1/library/apply")) { json(exchange, 200, libraryApply(exchange)); return; }
                if (path.equals("/v1/library/mark")) { json(exchange, 200, libraryMarkRequest(exchange)); return; }
                if (path.equals("/v1/types/merge")) { json(exchange, 200, typesMerge(exchange)); return; }
                if (path.equals("/v1/export")) { exportAgain(exchange); return; }
                JsonObject write = switch (path) {
                    case "/v1/rename/function" -> write(exchange, this::renameFunction);
                    case "/v1/rename/label" -> write(exchange, this::renameLabel);
                    case "/v1/create/function" -> write(exchange, this::createFunction);
                    case "/v1/delete/function" -> write(exchange, this::deleteFunction);
                    case "/v1/set/flow" -> write(exchange, this::setFlow);
                    case "/v1/clear/locals" -> write(exchange, this::clearLocals);
                    case "/v1/merge/functions" -> write(exchange, this::mergeFunctions);
                    case "/v1/rename/variable" -> write(exchange, this::renameVariable);
                    case "/v1/rename/variables" -> batch(exchange, this::renameVariable);
                    case "/v1/set/comments" -> batch(exchange, this::setComment);
                    case "/v1/set/signature" -> write(exchange, this::setSignature);
                    case "/v1/set/comment" -> write(exchange, this::setComment);
                    case "/v1/set/data" -> write(exchange, this::setData);
                    case "/v1/set/description" -> write(exchange, this::setDescription);
                    case "/v1/set/code-mode" -> write(exchange, this::setCodeMode);
                    case "/v1/redecode" -> write(exchange, this::redecode);
                    case "/v1/function/extend" -> write(exchange, this::extendFunction);
                    case "/v1/set/equate" -> write(exchange, this::setEquate);
                    case "/v1/preview/equate" -> setEquateInFunctions(previewBody(exchange));
                    case "/v1/library/candidate" -> write(exchange, this::libraryCandidate);
                    case "/v1/library/decline" -> write(exchange, this::libraryDecline);
                    case "/v1/library/release" -> write(exchange, this::libraryRelease);
                    case "/v1/type" -> write(exchange, this::addType);
                    case "/v1/save" -> write(exchange, body -> {
                        if (program.isChanged()) saveProgram("save");
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

    /**
     * The language patch this Ghidra was compiled with, from the marker
     * Scripts/make-patched-ghidra.sh leaves in it; null on a stock install. The
     * folder's name and the jar do not tell: the patched copy shares both.
     */
    private static String languagePatch() {
        try {
            File marker = new File(Application.getInstallationDirectory().getFile(false), "byteripper-language-patch");
            return marker.isFile() ? Files.readAllLines(marker.toPath()).get(0).trim() : null;
        } catch (Exception unreadable) {
            return null;
        }
    }

    private JsonObject hello() {
        JsonObject answer = identity();
        answer.addProperty("protocol", PROTOCOL);
        answer.addProperty("build", BUILD);
        answer.addProperty("ghidra", Application.getApplicationVersion());
        String languagePatch = languagePatch();
        if (languagePatch != null) answer.addProperty("language_patch", languagePatch);
        answer.addProperty("functions", program.getFunctionManager().getFunctionCount());
        answer.addProperty("changed", program.isChanged());
        answer.addProperty("modification", modification());
        answer.addProperty("writes", writes());
        if (lostFile != null && lostFile.isFile()) {
            try {
                answer.addProperty("writes_lost", Files.readString(lostFile.toPath()).trim());
            } catch (Exception error) {
                System.err.println("OWNER lost: " + error);
            }
        }
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
        JsonArray fragmentNames = new JsonArray();
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
                if (fragment(symbol.getStorage())) {
                    fragments++;
                    fragmentNames.add(symbol.getName());
                } else {
                    locals++;
                }
            }
        }
        String plate = function.getComment();
        boolean noPlate = plate == null || plate.isBlank();
        if (parameters == 0 && locals == 0 && fragments == 0 && !noPlate) return null;
        JsonObject answer = new JsonObject();
        if (parameters > 0) answer.addProperty("params", parameters);
        if (locals > 0) answer.addProperty("locals", locals);
        if (fragments > 0) {
            answer.addProperty("fragments", fragments);
            answer.add("fragment_names", fragmentNames);
        }
        if (noPlate) answer.addProperty("no_plate", true);
        return answer;
    }

    /** A decompiler piece of a register or a `unique:` space, not a stored variable. */
    private static boolean fragment(ghidra.program.model.listing.VariableStorage storage) {
        if (storage == null) return false;
        if (storage.isRegisterStorage() || storage.isUniqueStorage() || storage.isHashStorage()) return true;
        // A value the decompiler split over two registers — `EDX:4,EAX:4` for a
        // 64-bit one — is that same piece: `isRegisterStorage()` is true of a
        // single register only, so without this such a temporary counted as a
        // local the review had missed and kept a finished function from `full`.
        ghidra.program.model.pcode.Varnode[] pieces = storage.getVarnodes();
        if (pieces == null || pieces.length == 0) return false;
        for (ghidra.program.model.pcode.Varnode piece : pieces) {
            if (piece.getAddress().getAddressSpace().getType()
                    != ghidra.program.model.address.AddressSpace.TYPE_REGISTER) {
                return false;
            }
        }
        return true;
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
     * `USER_DEFINED`), `filter=unfinished` — the functions a review has not
     * passed — and `filter=fragments` — those with a decompiler's temporary a
     * review has not named or typed, which do not make a function unfinished
     * but still print in its C. Both decompile every function to see its
     * locals, and say how many they checked in `summary`.
     */
    private JsonObject functions(Map<String, String> query) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 500), 5000);
        String filter = query.getOrDefault("filter", "");
        if (!filter.isEmpty() && !filter.equals("unfinished") && !filter.equals("fragments")) {
            throw new Failure(400, "filter is \"unfinished\", \"fragments\" or left out");
        }
        boolean unfinished = filter.equals("unfinished");
        boolean withFragments = filter.equals("fragments");
        int fragmentsOnly = 0;
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
            JsonObject leftovers = unfinished || withFragments ? leftovers(function) : null;
            if (leftovers != null && !unfinished(leftovers) && leftovers.has("fragments")) fragmentsOnly++;
            if (unfinished && (leftovers == null || !unfinished(leftovers))) continue;
            if (withFragments && (leftovers == null || !leftovers.has("fragments"))) continue;
            JsonObject item = item(function);
            addLibraryMark(item, function);
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
        if (unfinished || withFragments) {
            JsonObject summary = new JsonObject();
            summary.addProperty("functions", scanned);
            summary.addProperty(filter, total);
            summary.addProperty("fragments_only", fragmentsOnly);
            answer.add("summary", summary);
        }
        return answer;
    }

    private static final java.util.regex.Pattern LINK =
        java.util.regex.Pattern.compile("\\[([^\\]\\n]+)\\]\\((0[xX][0-9A-Fa-f]+)\\)");
    private static final java.util.regex.Pattern DEFAULT_NAME =
        java.util.regex.Pattern.compile("(?:thunk_)?(?:FUN|LAB|SUB|DAT|PTR|UNK)_[0-9A-Fa-f]+");

    /**
     * Links in comments and the description whose text is a default name of
     * Ghidra's while the target now has a real one: a rename leaves them, and
     * the reader sees a name that no longer exists. Reported, not rewritten,
     * because a comment is its author's.
     */
    private JsonObject staleLinks() {
        JsonArray links = new JsonArray();
        ghidra.program.model.listing.Listing listing = program.getListing();
        ghidra.program.model.address.AddressIterator addresses =
            listing.getCommentAddressIterator(program.getMemory(), true);
        while (addresses.hasNext()) {
            Address at = addresses.next();
            for (CommentType kind : CommentType.values()) {
                addStaleLinks(links, listing.getComment(kind, at), hex(at), kind.name().toLowerCase(java.util.Locale.ROOT));
            }
        }
        addStaleLinks(links, Harvest.description(program), "description", "description");
        JsonObject answer = new JsonObject();
        answer.add("stale_links", links);
        return answer;
    }

    private void addStaleLinks(JsonArray links, String text, String at, String kind) {
        if (text == null) return;
        java.util.regex.Matcher link = LINK.matcher(text);
        while (link.find()) {
            if (!DEFAULT_NAME.matcher(link.group(1)).matches()) continue;
            Symbol target;
            try {
                target = program.getSymbolTable().getPrimarySymbol(address(link.group(2)));
            } catch (Failure notAnAddress) {
                continue;
            }
            if (target == null || target.getSource() == SourceType.DEFAULT
                || target.getName().equals(link.group(1))) continue;
            JsonObject item = new JsonObject();
            item.addProperty("at", at);
            item.addProperty("kind", kind);
            item.addProperty("text", link.group(1));
            item.addProperty("target", link.group(2));
            item.addProperty("name", target.getName());
            links.add(item);
        }
    }

    /**
     * Equates on a memory operand: a name on the displacement of `[reg+N]`.
     * `value` once took these for immediates, so each is a suspect to read;
     * one set on purpose by `operand` is listed too.
     */
    private JsonObject equatesOnMemory(Map<String, String> query) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 200), 1000);
        java.util.List<JsonObject> found = new java.util.ArrayList<>();
        java.util.Iterator<ghidra.program.model.symbol.Equate> equates = program.getEquateTable().getEquates();
        while (equates.hasNext()) {
            ghidra.program.model.symbol.Equate equate = equates.next();
            for (ghidra.program.model.symbol.EquateReference use : equate.getReferences()) {
                Instruction instruction = program.getListing().getInstructionAt(use.getAddress());
                int operand = use.getOpIndex();
                if (instruction == null || operand < 0 || operand >= instruction.getNumOperands()
                    || isImmediate(instruction, operand)) continue;
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(use.getAddress()));
                item.addProperty("name", equate.getDisplayName());
                item.addProperty("operand", operand);
                item.addProperty("text", instruction.toString());
                Function function = program.getFunctionManager().getFunctionContaining(use.getAddress());
                if (function != null) item.addProperty("function", function.getName());
                found.add(item);
            }
        }
        found.sort(java.util.Comparator.comparing(item -> item.get("address").getAsString()));
        JsonArray page = new JsonArray();
        for (int i = offset; i < found.size() && i < offset + limit; i++) page.add(found.get(i));
        JsonObject answer = identity();
        answer.addProperty("count", found.size());
        answer.add("equates", page);
        return answer;
    }

    /** An operand that is a constant by itself, not part of a memory reference. */
    private static boolean isImmediate(Instruction instruction, int index) {
        int type = instruction.getOperandType(index);
        return ghidra.program.model.lang.OperandType.isScalar(type)
            && !ghidra.program.model.lang.OperandType.isDynamic(type)
            && !ghidra.program.model.lang.OperandType.isAddress(type)
            && instruction.getScalar(index) != null;
    }

    /**
     * One name on a value wherever `functions` hold it as an immediate operand.
     * Only an immediate: a value by itself would also match a displacement or
     * an address. An operand that already has another name keeps it and is
     * listed in `skipped`, since a value like 4 means different things. The
     * value held another way, as an address, is listed in `not_immediate`: it
     * is there, and it is not what this names.
     */
    private JsonObject setEquateInFunctions(JsonObject body) throws Exception {
        if (body.has("address")) throw new Failure(400, "give `functions` or `address`, not both");
        if (body.has("operand")) throw new Failure(400, "`functions` finds the operands: it takes no `operand`");
        String name = required(body, "name");
        if (name.isEmpty()) throw new Failure(400, "`functions` names a value; removing is per `address`");
        String valueText = required(body, "value");
        long value;
        try {
            value = valueText.startsWith("0x") || valueText.startsWith("0X")
                ? Long.parseUnsignedLong(valueText.substring(2), 16) : Long.parseLong(valueText);
        } catch (NumberFormatException error) {
            throw new Failure(400, valueText + " is not a number");
        }
        java.util.List<Function> functions = new java.util.ArrayList<>();
        for (com.google.gson.JsonElement item : body.getAsJsonArray("functions")) {
            functions.add(functionAt(item.getAsString()));
        }
        boolean dryRun = body.has("dry_run") && body.get("dry_run").getAsBoolean();
        JsonArray applied = new JsonArray();
        JsonArray skipped = new JsonArray();
        JsonArray notImmediate = new JsonArray();
        ghidra.program.model.symbol.EquateTable table = program.getEquateTable();
        for (Function function : functions) {
            InstructionIterator instructions = program.getListing().getInstructions(function.getBody(), true);
            while (instructions.hasNext()) {
                Instruction instruction = instructions.next();
                for (int index = 0; index < instruction.getNumOperands(); index++) {
                    ghidra.program.model.scalar.Scalar scalar = instruction.getScalar(index);
                    if (scalar == null || (scalar.getUnsignedValue() != value && scalar.getSignedValue() != value)) continue;
                    Address at = instruction.getAddress();
                    if (!isImmediate(instruction, index)) {
                        JsonObject item = new JsonObject();
                        item.addProperty("address", hex(at));
                        item.addProperty("operand", index);
                        item.addProperty("text", instruction.toString());
                        notImmediate.add(item);
                        continue;
                    }
                    String held = null;
                    for (ghidra.program.model.symbol.Equate equate : table.getEquates(at, index)) {
                        if (!equate.getDisplayName().equals(name)) held = equate.getDisplayName();
                    }
                    if (held != null) {
                        JsonObject item = new JsonObject();
                        item.addProperty("address", hex(at));
                        item.addProperty("name", held);
                        skipped.add(item);
                        continue;
                    }
                    JsonObject item = new JsonObject();
                    item.addProperty("address", hex(at));
                    item.addProperty("text", instruction.toString());
                    applied.add(item);
                    if (dryRun) continue;
                    JsonObject one = body.deepCopy();
                    one.remove("functions");
                    one.remove("dry_run");
                    one.addProperty("address", hex(at));
                    one.addProperty("operand", index);
                    applyEquate(one);
                }
            }
        }
        JsonObject answer = identity();
        answer.addProperty("name", name);
        answer.addProperty("value", valueText);
        answer.addProperty("functions", functions.size());
        if (dryRun) answer.addProperty("dry_run", true);
        answer.add("applied", applied);
        answer.add("skipped", skipped);
        if (notImmediate.size() > 0) answer.add("not_immediate", notImmediate);
        return answer;
    }

    /**
     * Every comment in the function's body, by address and kind: what a re-read
     * of the C is checked against, since a stale step comment shows nowhere else.
     */
    private JsonArray commentsIn(Function function) {
        JsonArray comments = new JsonArray();
        ghidra.program.model.listing.Listing listing = program.getListing();
        ghidra.program.model.address.AddressIterator addresses =
            listing.getCommentAddressIterator(function.getBody(), true);
        while (addresses.hasNext()) {
            Address at = addresses.next();
            for (CommentType kind : CommentType.values()) {
                String text = listing.getComment(kind, at);
                if (text == null || text.isBlank()) continue;
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(at));
                item.addProperty("kind", kind.name().toLowerCase(java.util.Locale.ROOT));
                item.addProperty("text", text);
                comments.add(item);
            }
        }
        return comments;
    }

    /**
     * The gaps: spans of executable memory between neighbouring function
     * bodies that hold anything but padding. The analysis cuts a function
     * where a reference points — a call, a jump, an entry point — so a body
     * registered in a table, or reached by nothing at all, is left unclaimed:
     * 21 bodies in a 64-bit DXE driver whose analysis cut 535. A review starts
     * from this list rather than screening the gaps one at a time.
     *
     * Each entry says where the span lies, how long it is, where its first
     * non-padding byte is and what it is, and what refers into the span.
     * `verdict` carries the two signals a screen cannot do without: `body` —
     * a data reference lands in the span, so something registered it,
     * whatever its first bytes look like (`0x4F0C`: `MOV [RSP+8],RDI`, no
     * push, no frame, no stack subtraction); `tail` — nothing refers to it
     * and the body before it runs into it over padding, so it is that body's
     * tail and belongs with it, not in a function of its own.
     */
    private JsonObject gaps(Map<String, String> query) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 200), 2000);
        java.util.List<AddressRange> spans = new java.util.ArrayList<>();
        AddressSet covered = new AddressSet();
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            if (function.isExternal()) continue;
            for (AddressRange range : function.getBody().getAddressRanges()) covered.add(range);
        }
        for (MemoryBlock block : program.getMemory().getBlocks()) {
            if (!block.isExecute() || !block.isInitialized()) continue;
            AddressSetView inside = covered.intersect(new AddressSet(block.getStart(), block.getEnd()));
            Address cursor = block.getStart();
            for (AddressRange range : inside.getAddressRanges()) {
                if (cursor.compareTo(range.getMinAddress()) < 0) {
                    spans.add(new AddressRangeImpl(cursor, range.getMinAddress().previous()));
                }
                cursor = range.getMaxAddress().next();
                if (cursor == null) break;
            }
            if (cursor != null && cursor.compareTo(block.getEnd()) <= 0) {
                spans.add(new AddressRangeImpl(cursor, block.getEnd()));
            }
        }
        spans.sort(java.util.Comparator.comparing(AddressRange::getMinAddress));

        // One pass over every reference, indexed by where it points: the
        // reference iterator is ordered by the address a reference is made
        // from, so walking it per span would read the wrong end.
        int[] all = new int[spans.size()], data = new int[spans.size()], code = new int[spans.size()];
        java.util.List<java.util.List<String>> targets = new java.util.ArrayList<>();
        for (int index = 0; index < spans.size(); index++) targets.add(new java.util.ArrayList<>());
        ReferenceIterator references = program.getReferenceManager().getReferenceIterator(program.getMinAddress());
        while (references.hasNext()) {
            Reference reference = references.next();
            int index = indexOf(spans, reference.getToAddress());
            if (index < 0) continue;
            // A reference a body makes inside itself says nothing about the
            // span: only what points in from outside does.
            if (spans.get(index).contains(reference.getFromAddress())) continue;
            // The image's headers say where its sections start: not a table
            // that registers a body.
            MemoryBlock from = program.getMemory().getBlock(reference.getFromAddress());
            if (from != null && "Headers".equals(from.getName())) continue;
            all[index]++;
            // Something reading a datum that already has its type: not a body.
            if (reference.getReferenceType().isData()
                && program.getListing().getDefinedDataContaining(reference.getToAddress()) != null) continue;
            if (reference.getReferenceType().isData()) {
                data[index]++;
                if (targets.get(index).size() < 8) targets.get(index).add(hex(reference.getToAddress()));
            } else if (reference.getReferenceType().isCall() || reference.getReferenceType().isJump()) {
                code[index]++;
            }
        }

        java.util.List<JsonObject> found = new java.util.ArrayList<>();
        for (int index = 0; index < spans.size(); index++) {
            JsonObject gap = gap(spans.get(index), all[index], data[index], code[index], targets.get(index));
            if (gap != null) found.add(gap);
        }
        int total = found.size();
        int start = Math.min(offset, total), end = Math.min(start + limit, total);
        JsonArray page = new JsonArray();
        for (int index = start; index < end; index++) page.add(found.get(index));
        JsonObject answer = identity();
        answer.addProperty("count", total);
        answer.add("gaps", page);
        if (end < total) answer.addProperty("next", end);
        return answer;
    }

    /** The span holding `address`, or -1: the spans are sorted and apart. */
    private static int indexOf(java.util.List<AddressRange> spans, Address address) {
        int low = 0, high = spans.size() - 1;
        while (low <= high) {
            int middle = (low + high) >>> 1;
            AddressRange span = spans.get(middle);
            if (address.compareTo(span.getMinAddress()) < 0) high = middle - 1;
            else if (address.compareTo(span.getMaxAddress()) > 0) low = middle + 1;
            else return middle;
        }
        return -1;
    }

    /** One span between bodies, or null when it holds nothing but padding. */
    private JsonObject gap(AddressRange span, int all, int dataReferences, int codeReferences,
                           java.util.List<String> targets) {
        if (span.getLength() <= 0 || isPadding(span)) return null;
        Address first = span.getMinAddress();
        while (first.compareTo(span.getMaxAddress()) <= 0 && isPaddingByte(first)) first = first.next();
        if (first == null || first.compareTo(span.getMaxAddress()) > 0) return null;
        byte[] head = new byte[(int) Math.min(span.getMaxAddress().subtract(first) + 1, 16)];
        StringBuilder text = new StringBuilder();
        try {
            program.getMemory().getBytes(first, head);
            for (int index = 0; index < head.length; index++) {
                if (index > 0) text.append(' ');
                text.append(String.format("%02X", head[index] & 0xFF));
            }
        } catch (Exception error) {
            return null;
        }
        JsonObject gap = new JsonObject();
        gap.addProperty("start", hex(span.getMinAddress()));
        // Half-open, as every range the server gives: the byte after the span.
        gap.addProperty("end", "0x" + Long.toHexString(span.getMinAddress().getOffset() + span.getLength()).toUpperCase());
        gap.addProperty("size", (int) Math.min(span.getLength(), Integer.MAX_VALUE));
        gap.addProperty("first_non_padding", hex(first));
        gap.addProperty("first_bytes", text.toString());
        gap.addProperty("instruction", program.getListing().getInstructionAt(first) != null);
        gap.addProperty("defined_data", program.getListing().getDefinedDataContaining(first) != null);
        JsonObject counts = new JsonObject();
        counts.addProperty("all", all);
        counts.addProperty("data", dataReferences);
        counts.addProperty("code", codeReferences);
        gap.add("references", counts);
        if (!targets.isEmpty()) {
            JsonArray list = new JsonArray();
            for (String target : targets) list.add(target);
            gap.add("reference_targets", list);
            // Where a table points: the address to make a function at when the
            // gap is a registered body.
            gap.addProperty("body_at", targets.get(0));
        }
        boolean runsInto = runsInto(first);
        gap.addProperty("preceded_by_body", runsInto);
        String verdict;
        if (dataReferences > 0) verdict = "body";
        else if (all > 0 && codeReferences == 0) verdict = "data";
        else if (all == 0 && runsInto) verdict = "tail";
        else if (all == 0) verdict = "unclaimed";
        else verdict = "referenced";
        gap.addProperty("verdict", verdict);
        return gap;
    }

    /**
     * Whether the body before `address` runs into it: the last instruction
     * before it, padding set aside, falls through and is the last of a
     * function.
     */
    private boolean runsInto(Address address) {
        Address cursor = address.previous();
        while (cursor != null && isPaddingByte(cursor)) cursor = cursor.previous();
        if (cursor == null) return false;
        Instruction last = program.getListing().getInstructionContaining(cursor);
        if (last == null || !last.getMaxAddress().equals(cursor)) return false;
        if (last.getFlowType().isJump() || last.getFlowType().isTerminal()) return false;
        return program.getFunctionManager().getFunctionContaining(cursor) != null;
    }

    /** Whether one byte is padding: zero, 0xFF, int3 or nop. */
    private boolean isPaddingByte(Address address) {
        try {
            byte value = program.getMemory().getByte(address);
            return value == 0x00 || value == (byte) 0xFF || value == (byte) 0xCC || value == (byte) 0x90;
        } catch (Exception error) {
            return false;
        }
    }

    /** Whether every byte of the span is padding. */
    private boolean isPadding(AddressRange span) {
        long length = span.getLength();
        // A span too large to read is reported rather than tested: a module's
        // executable memory is far below this, and a silent skip would hide it.
        if (length > (16L << 20)) return false;
        byte[] bytes = new byte[(int) length];
        try {
            program.getMemory().getBytes(span.getMinAddress(), bytes);
        } catch (Exception error) {
            return false;
        }
        for (byte value : bytes) {
            if (value != 0x00 && value != (byte) 0xFF && value != (byte) 0xCC && value != (byte) 0x90) {
                return false;
            }
        }
        return true;
    }

    /**
     * One function. `summary=1` leaves the decompiled C and the equates out —
     * signature, parameters, locals, plate comment and what is left to name —
     * for walking a module without its text.
     */
    private JsonObject function(String text, Map<String, String> query) throws Failure {
        boolean summary = "1".equals(query.get("summary")) || "true".equals(query.get("summary"));
        boolean explain = "1".equals(query.get("explain")) || "true".equals(query.get("explain"));
        Function function = functionAt(text);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        answer.addProperty("name_source", function.getSymbol().getSource().toString());
        addLibraryMark(answer, function);
        answer.addProperty("signature", function.getPrototypeString(false, false));
        addTags(answer, function);
        JsonObject proposed = libraryCandidate(function);
        if (proposed != null) answer.add("library_candidate", proposed);
        StringPropertyMap signatureReasons =
            program.getUsrPropertyManager().getStringPropertyMap(Harvest.SIGNATURE_REASON);
        String signatureReason = signatureReasons == null ? null : signatureReasons.getString(function.getEntryPoint());
        if (signatureReason != null) answer.addProperty("signature_reason", signatureReason);
        StringPropertyMap nameReasons = program.getUsrPropertyManager().getStringPropertyMap(Harvest.REASON);
        String nameReason = nameReasons == null ? null : nameReasons.getString(function.getEntryPoint());
        if (nameReason != null) answer.addProperty("name_reason", nameReason);
        answer.addProperty("calling_convention", function.getCallingConventionName());
        JsonArray keptRegisters = keptRegisters(function);
        if (keptRegisters != null) answer.add("unaffected_kept", keptRegisters);
        String plate = function.getComment();
        if (plate != null && !plate.isBlank()) answer.addProperty("plate", plate);
        answer.add("comments", commentsIn(function));
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
                               ? ExportCode.indentedC(function, results) : null);
            JsonArray dataComments = dataCommentsOf(function);
            if (dataComments.size() > 0) answer.add("data_comments", dataComments);
        }
        if (results != null && !results.decompileCompleted()) {
            answer.addProperty("decompile_error", results.getErrorMessage());
            answer.add("suspects", decompileSuspects(function));
            if (explain) answer.add("explained", explainDecompileFailure(function));
        }
        return answer;
    }

    /**
     * The referenced data whose applied type stands between this body and its
     * C. Each datum is let go in turn and the function decompiled again inside
     * a transaction that is rolled back; the ones after which the C comes out
     * are named. A `PTRSUB off of non structured pointer type` is the printer
     * building a cast around one of them — a correctly typed global included —
     * and naming it turns a hand bisect of a long body into one call.
     *
     * Nothing is kept: every change is rolled back, and each answer says
     * whether the datum was found as it was afterwards; a rollback that did not
     * take stops the walk rather than report a program it did not leave.
     */
    private JsonArray explainDecompileFailure(Function function) {
        JsonArray unblocked = new JsonArray();
        java.util.LinkedHashMap<Address, Data> targets = new java.util.LinkedHashMap<>();
        InstructionIterator code = program.getListing().getInstructions(function.getBody(), true);
        while (code.hasNext()) {
            Instruction instruction = code.next();
            for (Reference reference : instruction.getReferencesFrom()) {
                Address to = reference.getToAddress();
                if (!to.isMemoryAddress()) continue;
                Data data = program.getListing().getDataAt(to);
                if (data == null || data.getDataType() == null) continue;
                targets.putIfAbsent(to, data);
            }
        }
        int tried = 0;
        for (java.util.Map.Entry<Address, Data> entry : targets.entrySet()) {
            if (tried++ >= 120) break;
            Address target = entry.getKey();
            Data data = entry.getValue();
            DataType original = data.getDataType();
            int length = Math.max(data.getLength(), 1);
            long before = program.getModificationNumber();
            int transaction = program.startTransaction("explain " + hex(target));
            boolean completed = false;
            try {
                program.getListing().clearCodeUnits(target, target.add(length - 1), false);
                completed = decompilesWithC(function);
            } catch (Exception error) {
                completed = false;
            } finally {
                endTransaction(transaction, false, before);
            }
            Data restored = program.getListing().getDataAt(target);
            boolean intact = restored != null && restored.getDataType() != null
                && restored.getDataType().getPathName().equals(original.getPathName());
            if (completed) {
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(target));
                item.addProperty("type", original.getPathName());
                if (data.getPrimarySymbol() != null) item.addProperty("name", data.getPrimarySymbol().getName());
                item.addProperty("restored", intact);
                unblocked.add(item);
            }
            if (!intact) {
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(target));
                item.addProperty("restored", false);
                item.addProperty("stopped", true);
                unblocked.add(item);
                break;
            }
        }
        return unblocked;
    }

    /** Whether the function decompiles with its C, on a decompiler of its own. */
    private boolean decompilesWithC(Function function) {
        ghidra.app.decompiler.DecompInterface probe = new ghidra.app.decompiler.DecompInterface();
        try {
            probe.setOptions(ExportCode.decompileOptions(program));
            probe.toggleCCode(true);
            probe.toggleSyntaxTree(true);
            probe.openProgram(program);
            ghidra.app.decompiler.DecompileResults results =
                probe.decompileFunction(function, 120, TaskMonitor.DUMMY);
            return results != null && results.decompileCompleted();
        } catch (Exception error) {
            return false;
        } finally {
            probe.dispose();
        }
    }

    /**
     * Where the decompiler may have choked: the parameters and locals, and the
     * data the body's instructions reference, whose type is a pointer to
     * something that is not a structure or an array — a `void *`, a scalar, an
     * enum. `PTRSUB off of non structured pointer type` comes from one of
     * these: the body computes a field offset on a pointer whose pointee says
     * it has no fields. The list is short by design; it saves bisecting the
     * body by hand.
     */
    /**
     * What is written on the data the function's instructions reach: no
     * function's C prints it, so a stale comment on a global shows nowhere a
     * review of the function looks.
     */
    private JsonArray dataCommentsOf(Function function) {
        JsonArray comments = new JsonArray();
        java.util.Set<Address> seen = new java.util.HashSet<>();
        InstructionIterator code = program.getListing().getInstructions(function.getBody(), true);
        while (code.hasNext()) {
            for (Reference reference : code.next().getReferencesFrom()) {
                Address to = reference.getToAddress();
                if (!to.isMemoryAddress() || !seen.add(to) || program.getListing().getDataAt(to) == null) continue;
                String said = ExportCode.dataComment(program.getListing(), to);
                if (said == null || said.isBlank()) continue;
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(to));
                ghidra.program.model.symbol.Symbol symbol = program.getSymbolTable().getPrimarySymbol(to);
                if (symbol != null) item.addProperty("name", symbol.getName());
                item.addProperty("comment", said);
                comments.add(item);
            }
        }
        return comments;
    }

    private JsonArray decompileSuspects(Function function) {
        JsonArray suspects = new JsonArray();
        java.util.Set<String> seen = new java.util.HashSet<>();
        for (Parameter parameter : function.getParameters()) {
            addSuspect(suspects, seen, "parameter", parameter.getName(), parameter.getDataType());
        }
        for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
            addSuspect(suspects, seen, "local", local.getName(), local.getDataType());
        }
        InstructionIterator code = program.getListing().getInstructions(function.getBody(), true);
        while (code.hasNext()) {
            Instruction instruction = code.next();
            for (Reference reference : instruction.getReferencesFrom()) {
                if (!reference.getToAddress().isMemoryAddress()) continue;
                Data data = program.getListing().getDataAt(reference.getToAddress());
                if (data == null || data.getDataType() == null) continue;
                String address = hex(reference.getToAddress());
                if (!seen.add("data " + address)) continue;
                addSuspect(suspects, seen, "data " + address,
                           data.getPrimarySymbol() == null ? null : data.getPrimarySymbol().getName(),
                           data.getDataType());
            }
        }
        return suspects;
    }

    private static void addSuspect(JsonArray into, java.util.Set<String> seen, String kind,
                                   String name, DataType type) {
        if (!(type instanceof ghidra.program.model.data.Pointer pointer)) return;
        DataType target = pointer.getDataType();
        if (target == null) return;
        DataType base = target instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : target;
        if (base instanceof ghidra.program.model.data.Composite) return;
        if (base instanceof ghidra.program.model.data.Array) return;
        String key = kind + " " + (name == null ? "" : name);
        if (!seen.add(key)) return;
        JsonObject item = new JsonObject();
        item.addProperty("kind", kind);
        if (name != null) item.addProperty("name", name);
        item.addProperty("type", type.getName());
        item.addProperty("points_to", base.getName());
        into.add(item);
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
        if (contains != null) answer.add("in_archives", archiveMatches(contains));
        return answer;
    }

    /**
     * The types of the shared review archive and of EDK2 a name search also
     * matches and the program does not hold yet. A program takes one the first
     * time it is used, so "none here" must not read as "define it": that is how
     * a duplicate of an archive's type gets written.
     */
    private JsonArray archiveMatches(String contains) {
        String wanted = contains.toLowerCase(java.util.Locale.ROOT);
        ghidra.program.model.data.DataTypeManager manager = program.getDataTypeManager();
        JsonArray found = new JsonArray();
        java.util.Set<String> seen = new java.util.HashSet<>();
        for (FileDataTypeManager source : new FileDataTypeManager[] {reviewArchive, archive}) {
            if (source == null) continue;
            Iterator<DataType> all = source.getAllDataTypes();
            while (all.hasNext() && found.size() < 50) {
                DataType type = all.next();
                if (type instanceof ghidra.program.model.data.BuiltInDataType) continue;
                if (!type.getName().toLowerCase(java.util.Locale.ROOT).contains(wanted)) continue;
                if (!seen.add(type.getName())) continue;
                java.util.List<DataType> held = new java.util.ArrayList<>();
                manager.findDataTypes(type.getName(), held);
                if (!held.isEmpty()) continue;
                JsonObject item = new JsonObject();
                item.addProperty("name", type.getName());
                item.addProperty("kind", kind(type));
                item.addProperty("size", type.getLength());
                item.addProperty("source", source == archive ? "edk2" : "review");
                found.add(item);
            }
        }
        return found;
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
        Function function = program.getFunctionManager().getFunctionContaining(address(text));
        // Code no function holds, as `ghidra_gaps` lists it: read to the next
        // function, which is what deciding what to make of a gap needs.
        Address gap = function == null ? address(text) : null;
        boolean undecoded = gap != null && program.getListing().getInstructionAt(gap) == null;
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
        if (undecoded) return undecodedBytes(gap, from, limit);
        JsonArray instructions = new JsonArray();
        String next = null;
        InstructionIterator iterator = function != null
            ? program.getListing().getInstructions(function.getBody(), true)
            : program.getListing().getInstructions(gap, true);
        while (iterator.hasNext()) {
            Instruction instruction = iterator.next();
            if (gap != null && program.getFunctionManager().getFunctionContaining(instruction.getAddress()) != null) break;
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
        if (function != null) answer.addProperty("entry", hex(function.getEntryPoint()));
        else answer.addProperty("gap", hex(gap));
        answer.add("instructions", instructions);
        if (next != null) answer.addProperty("next", next);
        return answer;
    }

    /** How many rows an undecoded gap answers when `limit` leaves it open. */
    private static final int UNDECODED_ROWS = 64;

    /**
     * Bytes no function and no instruction holds, decoded for reading only:
     * the program stays as it was, so a row here is what these bytes would be
     * if they were code, not a claim that they are. Stops at the first thing
     * the program does hold there, or at what does not decode.
     */
    private JsonObject undecodedBytes(Address gap, Address from, int limit) throws Failure {
        ghidra.program.model.listing.Listing listing = program.getListing();
        AddressSetView bytes = program.getMemory().getLoadedAndInitializedAddressSet();
        if (!bytes.contains(gap)) throw new Failure(404, "no function, no instruction and no bytes at " + hex(gap));
        ghidra.program.model.listing.Data data = listing.getDefinedDataContaining(gap);
        if (data != null) throw new Failure(404, hex(gap) + " is defined data (" + data.getDataType().getDisplayName() + "): ghidra_data reads it");
        ghidra.app.util.PseudoDisassembler decoder = new ghidra.app.util.PseudoDisassembler(program);
        JsonArray rows = new JsonArray();
        int most = limit == Integer.MAX_VALUE ? UNDECODED_ROWS : limit;
        Address at = from != null ? from : gap;
        String next = null, stopped = null;
        while (true) {
            if (!bytes.contains(at)) { stopped = "the end of the bytes"; break; }
            if (program.getFunctionManager().getFunctionContaining(at) != null) { stopped = "a function"; break; }
            if (listing.getInstructionAt(at) != null) { stopped = "an instruction"; break; }
            if (listing.getDefinedDataContaining(at) != null) { stopped = "defined data"; break; }
            if (rows.size() == most) { next = hex(at); break; }
            ghidra.app.util.PseudoInstruction instruction;
            try {
                instruction = decoder.disassemble(at);
            } catch (Exception error) {
                instruction = null;
            }
            if (instruction == null) { stopped = "bytes that do not decode"; break; }
            JsonObject row = new JsonObject();
            row.addProperty("address", hex(at));
            try {
                row.addProperty("bytes", hexBytes(instruction.getBytes()));
            } catch (Exception ignored) {
                row.addProperty("bytes", "");
            }
            row.addProperty("text", instruction.toString());
            row.add("references", new JsonArray());
            rows.add(row);
            try {
                at = at.addNoWrap(instruction.getLength());
            } catch (Exception error) {
                stopped = "the end of the bytes";
                break;
            }
        }
        JsonObject answer = identity();
        answer.addProperty("gap", hex(gap));
        answer.addProperty("undecoded", true);
        answer.add("instructions", rows);
        if (next != null) answer.addProperty("next", next);
        if (stopped != null) {
            answer.addProperty("stopped_at", hex(at));
            answer.addProperty("stopped_by", stopped);
        }
        return answer;
    }

    private JsonObject xrefs(Map<String, String> query) throws Failure {
        JsonArray list = new JsonArray();
        if (query.containsKey("to")) {
            Address to = address(query.get("to"));
            ReferenceIterator iterator = program.getReferenceManager().getReferencesTo(to);
            while (iterator.hasNext()) list.add(reference(iterator.next()));
            JsonObject answer = identity();
            answer.add("references", list);
            answer.add("held_by", constantHolders(to));
            return answer;
        } else if (query.containsKey("function")) {
            JsonObject answer = identity();
            answer.add("calls", calls(functionAt(query.get("function"))));
            return answer;
        } else if (query.containsKey("from")) {
            for (Reference reference : program.getReferenceManager().getReferencesFrom(address(query.get("from")))) {
                if (reference.getToAddress().isMemoryAddress()) list.add(reference(reference));
            }
        } else {
            throw new Failure(400, "xrefs needs to=, from= or function=");
        }
        JsonObject answer = identity();
        answer.add("references", list);
        return answer;
    }

    /** Which instructions hold each address of the image as a constant, for the program as it was at `constantsAt`. */
    private final java.util.Map<Long, java.util.List<Address>> constants = new java.util.HashMap<>();
    private long constantsAt = -1;

    /**
     * The instructions that hold `to` as a constant and have no reference to
     * it: `MOV EAX,imm` or `MOV [EBX],imm` carry none until something makes
     * one. A small constant in an image based at zero is not taken for an
     * address, as in `libraryOutside`.
     */
    private JsonArray constantHolders(Address to) {
        if (constantsAt != program.getModificationNumber()) {
            constants.clear();
            constantsAt = program.getModificationNumber();
            if (program.getImageBase().getOffset() >= 0x10000) {
                InstructionIterator instructions = program.getListing().getInstructions(true);
                while (instructions.hasNext()) {
                    Instruction instruction = instructions.next();
                    for (int operand = 0; operand < instruction.getNumOperands(); operand++) {
                        for (Object part : instruction.getOpObjects(operand)) {
                            if (!(part instanceof ghidra.program.model.scalar.Scalar scalar)) continue;
                            long value = scalar.getUnsignedValue();
                            Address held = imageAddress(value);
                            if (held == null) continue;
                            java.util.List<Address> holders = constants.computeIfAbsent(value, key -> new java.util.ArrayList<>());
                            if (!holders.contains(instruction.getAddress())) holders.add(instruction.getAddress());
                        }
                    }
                }
            }
        }
        JsonArray list = new JsonArray();
        for (Address at : constants.getOrDefault(to.getOffset(), java.util.List.of())) {
            Instruction instruction = program.getListing().getInstructionAt(at);
            if (instruction == null) continue;
            boolean referred = false;
            for (Reference reference : instruction.getReferencesFrom()) {
                referred = referred || reference.getToAddress().equals(to);
            }
            if (referred) continue;
            JsonObject item = new JsonObject();
            item.addProperty("from", hex(at));
            item.addProperty("text", instruction.toString());
            Function holder = program.getFunctionManager().getFunctionContaining(at);
            if (holder != null) item.addProperty("function", hex(holder.getEntryPoint()));
            list.add(item);
        }
        return list;
    }

    /** The address `value` is, when it is one the image holds. */
    private Address imageAddress(long value) {
        try {
            Address at = program.getImageBase().getNewAddress(value);
            return program.getMemory().contains(at) ? at : null;
        } catch (Exception error) {
            return null;
        }
    }

    /**
     * Every call a function makes, in order, and every jump that leaves it, so
     * that an empty list means no calls: `direct`, with its `target`; `indirect`,
     * with the `target` where a reference or the register's `MOV` gives it
     * (`held_at`), and without one where nothing here says where it goes.
     */
    private JsonArray calls(Function function) {
        JsonArray list = new JsonArray();
        InstructionIterator instructions = program.getListing().getInstructions(function.getBody(), true);
        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            ghidra.program.model.symbol.FlowType flow = instruction.getFlowType();
            Address[] flows = instruction.getFlows();
            boolean leaves = false;
            for (Address to : flows) leaves = leaves || !function.getBody().contains(to);
            boolean jump = flow.isJump();
            if (!flow.isCall() && !(jump && (leaves || (flow.isComputed() && flows.length == 0)))) continue;
            Address[] targets = flows.length == 0 ? new Address[] { null } : flows;
            for (Address target : targets) {
                if (jump && target != null && function.getBody().contains(target)) continue;
                JsonObject item = new JsonObject();
                item.addProperty("at", hex(instruction.getAddress()));
                item.addProperty("text", instruction.toString());
                item.addProperty("kind", flow.isComputed() ? "indirect" : "direct");
                if (jump) item.addProperty("jump", true);
                Address reached = target;
                if (reached == null) {
                    Instruction holder = constantInRegister(instruction, function);
                    if (holder != null) {
                        reached = imageAddress(((ghidra.program.model.scalar.Scalar) holder.getOpObjects(1)[0]).getUnsignedValue());
                        if (reached != null) item.addProperty("held_at", hex(holder.getAddress()));
                    }
                }
                if (reached != null) {
                    item.addProperty("target", hex(reached));
                    Function called = program.getFunctionManager().getFunctionAt(reached);
                    if (called != null) item.addProperty("name", called.getName());
                }
                list.add(item);
            }
        }
        return list;
    }

    private Instruction constantInRegister(Instruction call, Function function) {
        return ExportCode.constantInRegister(program, call, function);
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
        // `merge_types=0`: the export only, its conflicts worked out on a copy as
        // a preview's are. The host merges with `/v1/types/merge` once the
        // registry has said yes, so a refused publish leaves the shared
        // archive as it was.
        boolean mergeTypes = !"0".equals(parameters.get("merge_types"));
        if (!dryRun) writeLibraryStates();
        // Before the export: the artifact's types and the C read the named
        // members, and the merge below finds them in the same publish. A
        // preview names them too, so it compares what the publish would, and
        // gives them back when it has answered.
        long before = program.getModificationNumber();
        int transaction = program.startTransaction("type member names");
        boolean named = false;
        try {
            named = nameFunctionPointerMembers();
        } finally {
            if (!dryRun) endTransaction(transaction, named, before);
        }
        if (!dryRun && program.isChanged()) saveProgram("publish");
        try {
            byte[] artifact = exportArtifact();
            published = Harvest.of(program, options.get("module"), options.get("project-id"));
            Merge merge = mergeReviewTypes(!dryRun && mergeTypes, take);
            exchange.getResponseHeaders().set("X-Owner-Dry-Run", Boolean.toString(dryRun));
            exchange.getResponseHeaders().set("X-Owner-Types-Merged", Boolean.toString(!dryRun && mergeTypes));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("X-Owner-Modification", Long.toString(modification()));
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
            if (dryRun) endTransaction(transaction, false, before);
        }
    }

    /**
     * `POST /v1/types/merge`: the review's types into a shared archive, as a
     * publish without `merge_types=0` merges them. With `{"archive": DIR}` the
     * archive is `DIR/review-types-<bits>.gdt` and its sidecars — the copy of
     * the current version the server hands over while it decides a publish,
     * and keeps as the next version when the merge changed it; without it,
     * the archive beside the projects, as before versions. `take_type_conflicts=1`
     * as there. Merging again what is merged changes nothing.
     */
    private JsonObject typesMerge(HttpExchange exchange) throws Exception {
        requireLease(exchange);
        boolean take = "1".equals(query(exchange.getRequestURI().getRawQuery()).get("take_type_conflicts"));
        JsonObject body = body(exchange);
        Merge merge = mergeReviewTypes(true, take, archiveNamed(body));
        JsonObject answer = new JsonObject();
        answer.addProperty("changed", merge.written || merge.changed);
        JsonArray added = new JsonArray();
        for (String name : merge.added) added.add(name);
        JsonArray amended = new JsonArray();
        for (String name : merge.amended) amended.add(name);
        answer.add("added", added);
        answer.add("amended", amended);
        JsonArray conflicts = new JsonArray();
        for (String name : merge.conflicts) conflicts.add(name);
        JsonArray taken = new JsonArray();
        for (String name : merge.taken) taken.add(name);
        JsonObject origins = new JsonObject();
        for (java.util.Map.Entry<String, String> origin : merge.origins.entrySet()) {
            if (origin.getValue() != null && !origin.getValue().isEmpty()) origins.addProperty(origin.getKey(), origin.getValue());
        }
        answer.add("conflicts", conflicts);
        answer.add("taken", taken);
        answer.add("origins", origins);
        return answer;
    }

    /**
     * The archive a call names with `archive` — a folder of the server's —
     * or the one beside the projects. The folder must exist; the archive in
     * it need not, for the first version of a size.
     */
    private File archiveNamed(JsonObject body) throws Failure {
        if (body == null || !body.has("archive") || body.get("archive").isJsonNull()) {
            if (reviewTypes == null) throw new Failure(409, "this owner was started with no shared archive");
            return reviewTypes;
        }
        File folder = new File(body.get("archive").getAsString());
        if (!folder.isDirectory()) throw new Failure(400, "archive names no folder: " + folder.getPath());
        String bits = program.getDefaultPointerSize() == 8 ? "X64" : "Ia32";
        return new File(folder, "review-types-" + bits + ".gdt");
    }

    /** ExportCode run on the program in this process: the artifact's bytes. */
    private byte[] exportArtifact() throws Exception {
        File out = File.createTempFile("owner-export-", ".json");
        try {
            ExportCode export = new ExportCode();
            export.setScriptArgs(new String[] {out.getPath()});
            PrintWriter log = new PrintWriter(System.out, true);
            export.execute(new GhidraState(null, project.getProject(), program, null, null, null),
                           new ScriptControls(log, log, TaskMonitor.DUMMY));
            byte[] artifact = Files.readAllBytes(out.toPath());
            if (artifact.length == 0) throw new Failure(500, "the export wrote nothing");
            return artifact;
        } finally {
            out.delete();
        }
    }

    /**
     * A project from before moves were one step keeps library tags, and notes of
     * how a function stood to its entry. Neither means anything now: a tag's kind
     * goes into its function's mark, and a function with no mark is the module's.
     */
    private void retireLibraryTags() throws Exception {
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            String kind = null;
            boolean tagged = false;
            for (ghidra.program.model.listing.FunctionTag tag : function.getTags()) {
                if (tag == null) continue;
                String name = tag.getName().toLowerCase(java.util.Locale.ROOT);
                if (!name.startsWith("library")) continue;
                tagged = true;
                if (name.startsWith("library.")) kind = name.substring(8);
            }
            if (!tagged) continue;
            JsonObject mark = libraryMark(function);
            if (mark != null && !mark.has("kind") && kind != null) {
                mark.addProperty("kind", kind);
                propertyMap(LIBRARY_MARK).add(function.getEntryPoint(), COMPACT.toJson(mark));
            }
            removeLibraryTags(function);
        }
        program.getUsrPropertyManager().removePropertyMap("ByteRipper.libraryIssue");
    }

    /** The registry states the exporter reads, in a transaction of their own. */
    private void writeLibraryStates() throws Exception {
        long before = program.getModificationNumber();
        int transaction = program.startTransaction("library states");
        boolean done = false;
        try {
            refreshLibraryStates();
            done = true;
        } finally {
            endTransaction(transaction, done, before);
        }
    }

    /**
     * `POST /v1/export`: the artifact again, after a publish's marks changed
     * what it says of the registry — the program saved, nothing harvested
     * and no types merged: the review is the one just published.
     */
    private void exportAgain(HttpExchange exchange) throws Exception {
        requireLease(exchange);
        writeLibraryStates();
        if (program.isChanged()) saveProgram("library states");
        byte[] artifact = exportArtifact();
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, artifact.length);
        try (OutputStream body = exchange.getResponseBody()) {
            body.write(artifact);
        }
    }

    private FileChannel lockChannel() throws Exception { return lockChannel(reviewTypes); }

    private static FileChannel lockChannel(File archive) throws Exception {
        File lock = new File(archive.getPath() + ".lock");
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
        /** The names withdrawn from the shared archive: a publish does not bring them back. */
        JsonObject withdrawn = new JsonObject();
        /** A shared type was added or replaced: the sidecar has something to record. */
        boolean written;
        /** Something of the archive changed: a member, a comment, a description. */
        boolean changed;
        /** Types new to the archive, and types this publish amended. */
        final java.util.List<String> added = new java.util.ArrayList<>();
        final java.util.List<String> amended = new java.util.ArrayList<>();
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
        return mergeReviewTypes(apply, take, reviewTypes);
    }

    private Merge mergeReviewTypes(boolean apply, boolean take, File target) throws Exception {
        Merge merge = new Merge();
        java.util.TreeMap<String, String> mine = Harvest.reviewTypes(program);
        if (target == null || mine.isEmpty()) return merge;
        if (!apply) {
            if (!reviewTypes.isFile()) return merge;
            // The merge itself, on a copy: replacing one type can settle the
            // types made of it, so only doing it says what is left to do.
            File copy = File.createTempFile("review-types-preview-", ".gdt");
            try {
                JsonObject origins;
                try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
                    merge.withdrawn = readWithdrawn();
                    origins = readOrigins();
                    Files.copy(reviewTypes.toPath(), copy.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
                FileDataTypeManager shared = FileDataTypeManager.openFileArchive(copy, true);
                try {
                    int transaction = shared.startTransaction("preview of " + options.get("module"));
                    try {
                        mergeInto(shared, mine, merge, take, origins);
                    } finally {
                        shared.endTransaction(transaction, false);
                    }
                } finally {
                    shared.close();
                }
            } finally {
                copy.delete();
            }
            return merge;
        }
        target.getParentFile().mkdirs();
        try (FileChannel channel = lockChannel(target); FileLock lock = channel.lock()) {
            merge.withdrawn = readWithdrawn(target);
            FileDataTypeManager shared = target.isFile()
                ? FileDataTypeManager.openFileArchive(target, true)
                : FileDataTypeManager.createFileArchive(target, program.getLanguageID(),
                      program.getCompilerSpec().getCompilerSpecID());
            try {
                JsonObject origins = readOrigins(target);
                boolean changed = false;
                int transaction = shared.startTransaction("review types of " + options.get("module"));
                try {
                    changed = mergeInto(shared, mine, merge, take, origins);
                } finally {
                    shared.endTransaction(transaction, true);
                }
                if (changed) shared.save();
                merge.changed = changed;
                if (merge.written) writeOrigins(target, origins);
            } finally {
                shared.close();
            }
        }
        return merge;
    }

    /** The merge itself: into the archive for a publish, into a copy of it for a preview. */
    private boolean mergeInto(FileDataTypeManager shared, java.util.TreeMap<String, String> mine, Merge merge,
                              boolean take, JsonObject origins) throws Exception {
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
        java.util.Set<String> seen = new java.util.HashSet<>();
        for (java.util.Map.Entry<String, DataType> entry : ours.entrySet()) {
            String name = entry.getKey();
            DataType here = entry.getValue();
            if (mergeDeepestFirst(shared, name, here, ours, merge, take, origins, module, seen)) changed = true;
        }
        if (repairConflictNames(shared)) changed = true;
        return changed;
    }

    /**
     * The types a type is made of go first, at every depth: a structure that
     * differs because a member does is the member's conflict, named after the
     * member, not left to be resolved inside the structure, where Ghidra would
     * rename it `name.conflict`. And a comment settled in the deepest type is
     * no longer a difference of everything that holds it.
     */
    private boolean mergeDeepestFirst(FileDataTypeManager shared, String name, DataType here,
                                      java.util.TreeMap<String, DataType> ours, Merge merge, boolean take,
                                      JsonObject origins, String module, java.util.Set<String> seen) throws Exception {
        if (!seen.add(name)) return false;
        boolean changed = false;
        for (DataType member : membersOf(here, ours)) {
            String memberName = member.getName();
            if (memberName == null || memberName.isEmpty()) continue;
            if (mergeDeepestFirst(shared, memberName, member, ours, merge, take, origins, module, seen)) changed = true;
        }
        return mergeOne(shared, name, here, merge, take, origins, module) || changed;
    }

    /**
     * One type into the shared archive — the structure the review wrote or
     * one it is made of. An enum conflicts only on a member's value, another
     * type on its shape or, the shape being the same, on comments that cannot
     * be merged.
     */
    private boolean mergeOne(FileDataTypeManager shared, String name, DataType here, Merge merge,
                             boolean take, JsonObject origins, String module) throws Exception {
        // A withdrawn name stays out, and so does anything that would carry it
        // in: resolving a structure brings its members along. `take` does not
        // override this — that choice was made when the name was withdrawn.
        String carried = withdrawnWithin(here, merge.withdrawn);
        if (carried != null) {
            if (!merge.conflicts.contains(name)) merge.conflicts.add(name);
            merge.origins.put(name, "withdrawn " + carried);
            return false;
        }
        java.util.List<DataType> there = new java.util.ArrayList<>();
        shared.findDataTypes(name, there);
        if (there.isEmpty()) {
            shared.resolve(here, DataTypeConflictHandler.KEEP_HANDLER);
            merge.written = true;
            if (!merge.added.contains(name)) merge.added.add(name);
            recordOrigin(origins, name, module);
            return true;
        }
        DataType theirs = exactly(there, name);
        if (theirs == null) theirs = there.get(0);
        if (theirs instanceof ghidra.program.model.data.Enum sharedEnum
            && here instanceof ghidra.program.model.data.Enum ownEnum) {
            int merged = mergeEnum(ownEnum, sharedEnum);
            if (merged < 0) { recordConflict(merge, origins, name); return false; }
            if (merged > 0 && !merge.amended.contains(name)) merge.amended.add(name);
            return merged > 0;
        }
        // An equivalent structure whose members' types are named differently
        // is the normalisation the archive has not had yet — `_func_5 *Hook`
        // against `AMD_SOC_INFO_PPI_RN_Hook *Hook`. It is reported like a
        // difference so the publish that carries the names can take it, and
        // the archive then holds the names every module after it reads.
        boolean sameShape = sameShape(here, theirs, new java.util.HashSet<>());
        if (!sameShape || memberTypesRenamed(here, theirs)) {
            // Names given where the shared copy had only placeholders — a
            // field `Unknown08` named, a member type Ghidra called `_func_3`
            // named after its slot, a `param_1` named — and nothing else
            // different: the same type better read, an amendment, not a
            // replacement.
            if (replaceable(here, theirs) && onlyNamesGiven(here, theirs, new java.util.HashSet<>())) {
                if (!merge.amended.contains(name)) merge.amended.add(name);
                amendShared(shared, theirs, here);
                merge.written = true;
                recordOrigin(origins, name, module);
                return true;
            }
            if (take && replaceable(here, theirs)) {
                if (!merge.taken.contains(name)) merge.taken.add(name);
                merge.origins.put(name, originOf(origins, name));
                replaceShared(shared, theirs, here);
                merge.written = true;
                recordOrigin(origins, name, module);
                return true;
            }
            recordConflict(merge, origins, name);
            return false;
        }
        int merged = mergeComments(here, theirs);
        if (merged < 0) { recordConflict(merge, origins, name); return false; }
        if (merged > 0 && !merge.amended.contains(name)) merge.amended.add(name);
        return merged > 0;
    }

    /**
     * Whether `ours` is `theirs` with names given where `theirs` had only
     * placeholders, and nothing else: the same layout, member for member, at
     * every depth; a field named where the shared copy says `Unknown…`,
     * `field_0x…` or nothing; a member type named where Ghidra had made one
     * up (`_func_N`, a `.conflict` copy); a parameter named where it was
     * `param_N`. At least one such name must differ — otherwise the two are
     * simply the same.
     */
    private static boolean onlyNamesGiven(DataType ours, DataType theirs, java.util.Set<String> seen) {
        boolean[] given = {false};
        return namesOnlyGiven(ours, theirs, seen, given) && given[0];
    }

    private static boolean namesOnlyGiven(DataType a, DataType b, java.util.Set<String> seen, boolean[] given) {
        if (a == null || b == null) return a == b;
        if (!seen.add(a.getPathName() + "|" + b.getPathName())) return true;
        if (namesItsFunction(a) && !(b instanceof ghidra.program.model.data.TypeDef)) {
            return namesOnlyGiven(((ghidra.program.model.data.TypeDef) a).getBaseDataType(), b, seen, given);
        }
        if (namesItsFunction(b) && !(a instanceof ghidra.program.model.data.TypeDef)) {
            return namesOnlyGiven(a, ((ghidra.program.model.data.TypeDef) b).getBaseDataType(), seen, given);
        }
        if (!withoutConflictCopy(a.getName()).equals(withoutConflictCopy(b.getName()))) {
            if (!(madeUpTypeName(b.getName()) && !madeUpTypeName(a.getName()))) {
                // Pointers and arrays carry their target's name: compared below.
                if (!(a instanceof ghidra.program.model.data.Pointer) && !(a instanceof ghidra.program.model.data.Array)) {
                    return false;
                }
            } else {
                given[0] = true;
            }
        }
        if (a instanceof ghidra.program.model.data.Pointer p && b instanceof ghidra.program.model.data.Pointer q) {
            return p.getLength() == q.getLength() && namesOnlyGiven(p.getDataType(), q.getDataType(), seen, given);
        }
        if (a instanceof ghidra.program.model.data.Array p && b instanceof ghidra.program.model.data.Array q) {
            return p.getNumElements() == q.getNumElements() && namesOnlyGiven(p.getDataType(), q.getDataType(), seen, given);
        }
        if (a instanceof ghidra.program.model.data.TypeDef p && b instanceof ghidra.program.model.data.TypeDef q) {
            return namesOnlyGiven(p.getDataType(), q.getDataType(), seen, given);
        }
        if (a instanceof ghidra.program.model.data.Structure p && b instanceof ghidra.program.model.data.Structure q) {
            return fieldsOnlyGiven(p, q, seen, given);
        }
        if (a instanceof ghidra.program.model.data.Composite p && b instanceof ghidra.program.model.data.Composite q) {
            if ((p instanceof ghidra.program.model.data.Union) != (q instanceof ghidra.program.model.data.Union)) return false;
            ghidra.program.model.data.DataTypeComponent[] left = p.getDefinedComponents();
            ghidra.program.model.data.DataTypeComponent[] right = q.getDefinedComponents();
            if (p.getLength() != q.getLength() || left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) {
                if (left[i].getOffset() != right[i].getOffset() || left[i].getLength() != right[i].getLength()) return false;
                String mine = left[i].getFieldName();
                String shared = right[i].getFieldName();
                if (!java.util.Objects.equals(mine, shared)) {
                    if (!placeholderField(shared) || placeholderField(mine)) return false;
                    given[0] = true;
                }
                if (!namesOnlyGiven(left[i].getDataType(), right[i].getDataType(), seen, given)) return false;
            }
            return true;
        }
        if (a instanceof ghidra.program.model.data.FunctionDefinition p
            && b instanceof ghidra.program.model.data.FunctionDefinition q) {
            ghidra.program.model.data.ParameterDefinition[] left = p.getArguments();
            ghidra.program.model.data.ParameterDefinition[] right = q.getArguments();
            if (left.length != right.length || p.hasVarArgs() != q.hasVarArgs()
                || !java.util.Objects.equals(p.getCallingConventionName(), q.getCallingConventionName())) return false;
            if (!namesOnlyGiven(p.getReturnType(), q.getReturnType(), seen, given)) return false;
            for (int i = 0; i < left.length; i++) {
                String mine = left[i].getName();
                String shared = right[i].getName();
                if (!java.util.Objects.equals(mine, shared)) {
                    if (!placeholderParameter(shared) || placeholderParameter(mine)) return false;
                    given[0] = true;
                }
                if (!namesOnlyGiven(left[i].getDataType(), right[i].getDataType(), seen, given)) return false;
            }
            return true;
        }
        return a.isEquivalent(b) || sameShape(a, b, new java.util.HashSet<>());
    }

    /**
     * A structure read further than the shared copy: every shared field is
     * the module's at the same offset and size, named where the shared one
     * was a placeholder — or it is filler, a placeholder over bytes nobody
     * typed (`UINT8 Unknown04[24]`, `undefined4`), and the module's fields
     * cut it into what the code proves, none of them crossing its edges.
     * Fields where the shared copy holds no field at all are added. The
     * size stays the same, and a field the shared copy names keeps its
     * place, size and name.
     */
    private static boolean fieldsOnlyGiven(ghidra.program.model.data.Structure ours,
                                           ghidra.program.model.data.Structure theirs,
                                           java.util.Set<String> seen, boolean[] given) {
        if (ours.getLength() != theirs.getLength()) return false;
        ghidra.program.model.data.DataTypeComponent[] left = ours.getDefinedComponents();
        ghidra.program.model.data.DataTypeComponent[] right = theirs.getDefinedComponents();
        for (ghidra.program.model.data.DataTypeComponent shared : right) {
            int start = shared.getOffset(), end = start + shared.getLength();
            boolean filler = placeholderField(shared.getFieldName()) && filler(shared.getDataType());
            ghidra.program.model.data.DataTypeComponent same = null;
            for (ghidra.program.model.data.DataTypeComponent mine : left) {
                if (mine.getOffset() == start && mine.getLength() == shared.getLength()) { same = mine; break; }
            }
            if (same != null) {
                String mine = same.getFieldName(), theirName = shared.getFieldName();
                if (!java.util.Objects.equals(mine, theirName)) {
                    if (!placeholderField(theirName) || placeholderField(mine)) return false;
                    given[0] = true;
                }
                // Bytes the module typed where the shared copy had none.
                if (filler && !filler(same.getDataType())) { given[0] = true; continue; }
                if (!namesOnlyGiven(same.getDataType(), shared.getDataType(), seen, given)) return false;
                continue;
            }
            // A field the shared copy names, moved, resized or gone: a replacement.
            if (!filler) return false;
            for (ghidra.program.model.data.DataTypeComponent mine : left) {
                int from = mine.getOffset(), to = from + mine.getLength();
                if (to <= start || from >= end) continue;
                if (from < start || to > end) return false;
                if (!placeholderField(mine.getFieldName()) || !filler(mine.getDataType())) given[0] = true;
            }
        }
        // The module's fields over bytes the shared copy left without a field.
        for (ghidra.program.model.data.DataTypeComponent mine : left) {
            int from = mine.getOffset(), to = from + mine.getLength();
            boolean covered = false;
            for (ghidra.program.model.data.DataTypeComponent shared : right) {
                int start = shared.getOffset(), end = start + shared.getLength();
                if (to > start && from < end) { covered = true; break; }
            }
            if (!covered) given[0] = true;
        }
        return true;
    }

    /** Bytes nobody typed: `undefined`, `undefinedN`, or an array of one-byte elements. */
    static boolean filler(DataType type) {
        if (type == null) return true;
        if (type instanceof ghidra.program.model.data.TypeDef def) type = def.getBaseDataType();
        if (type instanceof ghidra.program.model.data.Undefined || type instanceof ghidra.program.model.data.DefaultDataType) return true;
        if (type instanceof ghidra.program.model.data.Array array) {
            DataType element = array.getDataType();
            if (element instanceof ghidra.program.model.data.TypeDef def) element = def.getBaseDataType();
            return element.getLength() == 1 && (element instanceof ghidra.program.model.data.Undefined
                || element instanceof ghidra.program.model.data.DefaultDataType
                || element instanceof ghidra.program.model.data.ByteDataType
                || element instanceof ghidra.program.model.data.UnsignedCharDataType
                || element instanceof ghidra.program.model.data.CharDataType
                || element instanceof ghidra.program.model.data.SignedByteDataType);
        }
        return false;
    }

    /** A type name Ghidra made up: an inline function type, or a `.conflict` copy. */
    static boolean madeUpTypeName(String name) {
        if (name == null) return true;
        String bare = name.replace(" ", "").replaceAll("\\*+$", "");
        return bare.matches("_func_\\d+(\\.conflict\\d*)?") || bare.matches(".*\\.conflict\\d*");
    }

    /** A field name that says nobody knew: none, `Unknown…`, `field_0x…`, `field1_0x…`. */
    static boolean placeholderField(String name) {
        return name == null || name.isEmpty() || name.matches("(?i)unknown[0-9a-f_]*")
            || name.matches("field\\d*_0x[0-9a-fA-F]+");
    }

    /** A parameter name Ghidra made up. */
    static boolean placeholderParameter(String name) {
        return name == null || name.isEmpty() || name.matches("param_\\d+");
    }

    /**
     * The function-pointer members of the review's structures, named after the
     * structure and the field. The decompiler makes one type per inline member
     * and names it `_func_N` per program, in the order it parsed them: the same
     * member is `_func_1` here and `_func_7` in the next module, and two
     * structures can come to share one name — which is how the shared archive
     * came to hold `.conflict` copies of a component. A name made from the
     * structure and the field belongs to one member of one structure and cannot
     * collide. The field's name and comment stay where they are: only the
     * component's type changes.
     *
     * Run at every publish over the types the review recorded, so a type
     * defined before this existed is renamed once, and its recorded C with it —
     * a change of the review document, so the publish after it is a revision.
     */
    private boolean nameFunctionPointerMembers() {
        boolean changed = false;
        for (String name : new java.util.ArrayList<>(Harvest.reviewTypes(program).keySet())) {
            DataType type = find(program.getDataTypeManager(), name);
            if (type == null || type.getDataTypeManager() != program.getDataTypeManager()) continue;
            if (!nameFunctionPointerMembers(type)) continue;
            changed = true;
            Harvest.recordType(program, type.getName(), ExportCode.typeC(type));
        }
        return changed;
    }

    private static boolean nameFunctionPointerMembers(DataType type) {
        DataType base = type instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : type;
        if (!(base instanceof ghidra.program.model.data.Composite composite)) return false;
        boolean changed = false;
        for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
            DataType fieldType = component.getDataType();
            boolean pointer = fieldType instanceof ghidra.program.model.data.Pointer;
            DataType target = pointer
                ? ((ghidra.program.model.data.Pointer) fieldType).getDataType() : fieldType;
            if (!(target instanceof ghidra.program.model.data.FunctionDefinition definition)) continue;
            String field = component.getFieldName();
            if (field == null || field.isEmpty()) continue;
            String wanted = type.getName() + "_" + field;
            if (wanted.equals(definition.getName())) continue;
            try {
                ghidra.program.model.data.DataTypeManager manager = composite.getDataTypeManager();
                DataType copied = definition.copy(manager);
                copied.setName(wanted);
                try {
                    String said = definition.getDescription();
                    if (said != null && !said.isEmpty()) copied.setDescription(said);
                } catch (Exception refused) {
                    // A function definition refuses a description on its
                    // in-memory copy; what a reader sees is the field's own
                    // comment, and that stays with the component.
                }
                DataType resolved = manager.resolve(copied, DataTypeConflictHandler.KEEP_HANDLER);
                DataType replacement = pointer ? manager.getPointer(resolved) : resolved;
                if (composite instanceof ghidra.program.model.data.Structure structure) {
                    structure.replaceAtOffset(component.getOffset(), replacement, component.getLength(),
                                              component.getFieldName(), component.getComment());
                } else {
                    // A union has no place to replace at: its members all
                    // start at zero, and only their order tells them apart.
                    int ordinal = component.getOrdinal();
                    int length = component.getLength();
                    String comment = component.getComment();
                    composite.delete(ordinal);
                    composite.insert(ordinal, replacement, length, field, comment);
                }
                changed = true;
            } catch (Exception error) {
                System.out.println("OWNER TYPE member " + wanted + ": " + error.getMessage());
            }
        }
        return changed;
    }

    /**
     * Whether two equivalent composites name their members' types
     * differently: the same layout, written when the members were still
     * `_func_N` and written again after they were named.
     */
    private static boolean memberTypesRenamed(DataType here, DataType theirs) {
        DataType ownBase = here instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : here;
        DataType sharedBase = theirs instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : theirs;
        if (!(ownBase instanceof ghidra.program.model.data.Composite mine)
            || !(sharedBase instanceof ghidra.program.model.data.Composite shared)) return false;
        ghidra.program.model.data.DataTypeComponent[] from = mine.getDefinedComponents();
        ghidra.program.model.data.DataTypeComponent[] to = shared.getDefinedComponents();
        if (from.length != to.length) return false;
        for (int i = 0; i < from.length; i++) {
            String left = from[i].getDataType().getName();
            String right = to[i].getDataType().getName();
            if (left == null || right == null) continue;
            if (!withoutConflictCopy(left).equals(withoutConflictCopy(right))) return true;
        }
        return false;
    }

    /** The description and the field comments, as `ghidra_type_definition` shows them. */
    private static boolean sameTexts(DataType here, DataType theirs) {
        JsonObject mine = TypeText.describe(here).getAsJsonObject();
        JsonObject shared = TypeText.describe(theirs).getAsJsonObject();
        if (!java.util.Objects.equals(mine.get("description"), shared.get("description"))) return false;
        JsonArray left = mine.has("fields") ? mine.getAsJsonArray("fields") : new JsonArray();
        JsonArray right = shared.has("fields") ? shared.getAsJsonArray("fields") : new JsonArray();
        if (left.size() != right.size()) return false;
        for (int i = 0; i < left.size(); i++) {
            if (!java.util.Objects.equals(left.get(i).getAsJsonObject().get("comment"),
                                          right.get(i).getAsJsonObject().get("comment"))) return false;
        }
        return true;
    }

    /** A typedef whose base is a function definition of the same name, `.conflict` aside. */
    static boolean namesItsFunction(DataType type) {
        if (!(type instanceof ghidra.program.model.data.TypeDef def)) return false;
        DataType base = def.getBaseDataType();
        return base instanceof ghidra.program.model.data.FunctionDefinition
            && withoutConflictCopy(base.getName()).equals(withoutConflictCopy(def.getName()));
    }

    /**
     * A name with Ghidra's `.conflict` suffix taken off. The archive stores a
     * type under `X.conflict` when it already holds another type named `X` —
     * a typedef and the function it names, say — and stores it so again at
     * every merge: `X.conflict` against `X` is the same type, not a name to
     * give, or every publish would write it again.
     */
    static String withoutConflictCopy(String name) {
        return name == null ? null : name.replaceAll("\\.conflict\\d*(?=[\\s*\\[]|$)", "");
    }

    /**
     * The same type under its two names. `isEquivalent` of a function
     * definition compares the description as well, and a copy the archive made
     * can carry one the twin does not; the signature is what says the two are
     * one type.
     */
    private static boolean sameShapeIgnoringComments(DataType twin, DataType copy) {
        if (twin instanceof ghidra.program.model.data.FunctionDefinition a
            && copy instanceof ghidra.program.model.data.FunctionDefinition b) {
            String left = a.getPrototypeString(false).replace(a.getName(), "#");
            String right = b.getPrototypeString(false).replace(b.getName(), "#");
            return left.equals(right);
        }
        return twin.isEquivalent(copy);
    }

    /** The types a structure is made of that this review also defines. */
    private static java.util.List<DataType> membersOf(DataType type,
                                                      java.util.TreeMap<String, DataType> ours) {
        java.util.List<DataType> found = new java.util.ArrayList<>();
        DataType base = type instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : type;
        if (!(base instanceof ghidra.program.model.data.Composite composite)) return found;
        for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
            DataType field = component.getDataType();
            DataType target = field instanceof ghidra.program.model.data.Pointer pointer
                ? pointer.getDataType() : field;
            if (target == null) continue;
            DataType memberBase = target instanceof ghidra.program.model.data.TypeDef def
                ? def.getBaseDataType() : target;
            if (memberBase == null) continue;
            String name = memberBase.getName();
            if (name == null || name.isEmpty()) continue;
            // A review type, a type a review's structure is a typedef of, or a
            // function-pointer member normalised to `<STRUCT>_<field>`: the
            // three the archive has to be told about before the structure.
            boolean review = ours.containsKey(name) || name.startsWith(type.getName() + "_");
            if (!review) continue;
            if (!found.contains(memberBase)) found.add(memberBase);
        }
        return found;
    }

    /**
     * The `.conflict` copies an older merge left behind. Ghidra names an
     * incoming type that way when the archive already holds one of its name,
     * and a component resolved implicitly could be stored so while its twin
     * stayed the type in use — the archive then carried a name that says
     * "conflict" for a type that is not one. A copy that is the same type as
     * its twin is a duplicate: the twin takes its uses, and it goes.
     *
     * One repair can make the next: a structure whose member was a copy reads
     * the same as its own copy once the member is the twin. The passes go on
     * until one finds nothing, so a publish leaves nothing for the next.
     */
    private static boolean repairConflictNames(FileDataTypeManager shared) {
        boolean changed = false;
        for (int pass = 0; pass < 16 && repairConflictNamesOnce(shared); pass++) changed = true;
        return changed;
    }

    private static boolean repairConflictNamesOnce(FileDataTypeManager shared) {
        boolean changed = false;
        // Taken from the listing: `findDataTypes` reads past the suffix, so
        // asking it for `X.conflict` answers X, which then "replaces" itself.
        java.util.List<DataType> copies = new java.util.ArrayList<>();
        for (java.util.Iterator<DataType> all = shared.getAllDataTypes(); all.hasNext(); ) {
            DataType type = all.next();
            if (type.getName().endsWith(".conflict")) copies.add(type);
        }
        for (DataType copy : copies) {
            if (copy.isDeleted()) continue;
            String name = copy.getName();
            String canonical = name.substring(0, name.length() - ".conflict".length());
            java.util.List<DataType> found = new java.util.ArrayList<>();
            shared.findDataTypes(canonical, found);
            DataType twin = exactly(found, canonical);
            if (twin == null) continue;
            // The same type, or a typedef that only renames the twin function:
            // either way the twin takes its uses.
            boolean same = sameShapeIgnoringComments(twin, copy)
                || (namesItsFunction(copy) && sameShapeIgnoringComments(
                        twin, ((ghidra.program.model.data.TypeDef) copy).getBaseDataType()));
            if (!same) continue;
            try {
                shared.replaceDataType(copy, twin, true);
                changed = true;
            } catch (Exception error) {
                System.out.println("OWNER TYPE repair " + name + ": " + error.getMessage());
            }
        }
        return changed;
    }

    /** The type of exactly this name: a lookup also answers its `.conflict` copies. */
    private static DataType exactly(java.util.List<DataType> found, String name) {
        for (DataType type : found) {
            if (name.equals(type.getName())) return type;
        }
        return null;
    }

    /** A take replaces a structure, a union or a typedef — never an enum. */
    private static boolean replaceable(DataType own, DataType shared) {
        return !(own instanceof ghidra.program.model.data.Enum)
            && !(shared instanceof ghidra.program.model.data.Enum);
    }

    private static void recordConflict(Merge merge, JsonObject origins, String name) {
        // A type several others are made of is asked about for each of them.
        if (!merge.conflicts.contains(name)) merge.conflicts.add(name);
        merge.origins.put(name, originOf(origins, name));
    }

    /**
     * The shared archive's copy of a type replaced by this review's. The only
     * caller is a publish with `take_type_conflicts`, which is the person's
     * choice made explicit; a type the archive cannot replace — one another
     * type still holds — stops the publish with 409 rather than leaving half
     * of a correction behind.
     */
    /**
     * An amendment: the module's type takes the shared one's place, and what
     * the shared one says that the module's does not is kept — a field's
     * comment where the module's field at the same offset and length has
     * none, and the description where the module gives none. An amendment
     * only adds; a module that never wrote a comment does not erase one.
     */
    private static void amendShared(FileDataTypeManager shared, DataType theirs, DataType ours) throws Exception {
        DataType theirBase = theirs instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null
            ? def.getBaseDataType() : theirs;
        java.util.Map<String, String> comments = new java.util.HashMap<>();
        if (theirBase instanceof ghidra.program.model.data.Composite composite) {
            for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
                String comment = component.getComment();
                if (comment != null && !comment.isEmpty()) {
                    comments.put(component.getOffset() + ":" + component.getLength(), comment);
                }
            }
        }
        String description = theirBase.getDescription();
        ghidra.program.model.data.CategoryPath path = theirs.getCategoryPath();
        String name = theirs.getName();
        replaceShared(shared, theirs, ours);
        DataType now = shared.getDataType(path, name);
        if (now == null) return;
        DataType base = now instanceof ghidra.program.model.data.TypeDef def && def.getBaseDataType() != null
            ? def.getBaseDataType() : now;
        if (base instanceof ghidra.program.model.data.Composite composite) {
            for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
                String kept = comments.get(component.getOffset() + ":" + component.getLength());
                String comment = component.getComment();
                if (kept != null && (comment == null || comment.isEmpty())) component.setComment(kept);
            }
        }
        String said = base.getDescription();
        if (description != null && !description.isEmpty() && (said == null || said.isEmpty())) {
            try { base.setDescription(description); } catch (Exception refused) { /* a type that keeps none */ }
        }
    }

    private static void replaceShared(FileDataTypeManager shared, DataType theirs, DataType ours) throws Exception {
        try {
            shared.replaceDataType(theirs, ours, true);
        } catch (Exception error) {
            throw new Failure(409, theirs.getName() + " cannot replace the shared " + theirs.getName()
                              + ": " + error.getMessage());
        }
    }

    /** The types a type is made of, directly: through pointers and arrays to the named one. */
    private static java.util.List<DataType> madeOf(DataType type) {
        java.util.List<DataType> parts = new java.util.ArrayList<>();
        if (type instanceof ghidra.program.model.data.TypeDef def) {
            parts.add(def.getDataType());
        } else if (type instanceof ghidra.program.model.data.Composite composite) {
            for (ghidra.program.model.data.DataTypeComponent component : composite.getDefinedComponents()) {
                parts.add(component.getDataType());
            }
        } else if (type instanceof ghidra.program.model.data.FunctionDefinition function) {
            parts.add(function.getReturnType());
            for (ghidra.program.model.data.ParameterDefinition parameter : function.getArguments()) {
                parts.add(parameter.getDataType());
            }
        }
        java.util.List<DataType> named = new java.util.ArrayList<>();
        for (DataType part : parts) {
            DataType at = part;
            while (at instanceof ghidra.program.model.data.Pointer || at instanceof ghidra.program.model.data.Array) {
                at = at instanceof ghidra.program.model.data.Pointer pointer
                    ? pointer.getDataType() : ((ghidra.program.model.data.Array) at).getDataType();
            }
            if (at != null) named.add(at);
        }
        return named;
    }

    /** The withdrawn name `type` is or is made of, however deep; null when none. */
    private static String withdrawnWithin(DataType type, JsonObject withdrawn) {
        if (withdrawn.size() == 0) return null;
        java.util.Set<String> seen = new java.util.HashSet<>();
        java.util.ArrayDeque<DataType> waiting = new java.util.ArrayDeque<>();
        waiting.add(type);
        while (!waiting.isEmpty()) {
            DataType at = waiting.poll();
            if (!seen.add(at.getPathName())) continue;
            if (withdrawn.has(at.getName())) return at.getName();
            waiting.addAll(madeOf(at));
        }
        return null;
    }

    /**
     * Takes a type out of the shared archive: a name that turned out false. A
     * typedef and the structure it names are one type and go together; another
     * archive type using either refuses it, since Ghidra would rewrite that type
     * around the gap. Who and why go in a sidecar with the type's C, which is
     * also what keeps a module holding a copy from publishing the name back. A
     * module's own copy stays: `ghidra_type_uses` lists what still names it.
     */
    private JsonObject withdrawShared(JsonObject body) throws Exception {
        String name = required(body, "name").trim();
        String reason = string(body, "reason", "").trim();
        if (reason.isEmpty()) throw new Failure(400, "taking a type out of the shared archive needs a reason");
        // The archive the server names — its copy of the current version, kept
        // as the next one when this is done — or the one beside the projects.
        File target = archiveNamed(body);
        if (!target.isFile()) throw new Failure(404, "there is no shared archive here");
        String alternate = name.startsWith("_") ? name.substring(1) : "_" + name;
        JsonArray gone = new JsonArray();
        try (FileChannel channel = lockChannel(target); FileLock lock = channel.lock()) {
            JsonObject withdrawn = readWithdrawn(target);
            FileDataTypeManager shared = FileDataTypeManager.openFileArchive(target, true);
            try {
                DataType found = findAny(shared, name, alternate);
                if (found == null) {
                    throw new Failure(404, withdrawn.has(name) || withdrawn.has(alternate)
                        ? name + " is already withdrawn from the shared archive"
                        : "no type " + name + " in the shared archive");
                }
                java.util.Map<String, DataType> group = new java.util.LinkedHashMap<>();
                group.put(found.getPathName(), found);
                if (found instanceof ghidra.program.model.data.TypeDef def
                    && def.getBaseDataType().getDataTypeManager() == shared
                    && !(def.getBaseDataType() instanceof ghidra.program.model.data.Pointer)) {
                    group.put(def.getBaseDataType().getPathName(), def.getBaseDataType());
                }
                java.util.List<DataType> all = new java.util.ArrayList<>();
                shared.getAllDataTypes(all);
                for (DataType type : all) {
                    if (type instanceof ghidra.program.model.data.TypeDef def
                        && group.containsKey(def.getDataType().getPathName())) {
                        group.put(type.getPathName(), type);
                    }
                }
                java.util.TreeSet<String> users = new java.util.TreeSet<>();
                for (DataType type : all) {
                    if (group.containsKey(type.getPathName()) || type instanceof ghidra.program.model.data.Pointer
                        || type instanceof ghidra.program.model.data.Array) continue;
                    for (DataType part : madeOf(type)) {
                        if (group.containsKey(part.getPathName())) users.add(type.getName());
                    }
                }
                if (!users.isEmpty()) {
                    throw new Failure(409, found.getName() + " is used by other types of the shared archive: "
                                      + String.join(", ", users) + ". Withdraw or correct those first.");
                }
                java.util.List<DataType> order = new java.util.ArrayList<>(group.values());
                order.sort(java.util.Comparator.comparingInt(type -> type instanceof ghidra.program.model.data.TypeDef ? 0 : 1));
                JsonObject origins = readOrigins(target);
                String at = java.time.Instant.now().toString();
                int transaction = shared.startTransaction("withdraw " + found.getName());
                boolean done = false;
                try {
                    for (DataType type : order) {
                        String typeName = type.getName();
                        JsonObject record = new JsonObject();
                        record.addProperty("by", leaseHolder);
                        record.addProperty("reason", reason);
                        record.addProperty("module", options.get("module"));
                        record.addProperty("at", at);
                        record.addProperty("c", ExportCode.typeC(type));
                        if (!shared.remove(type)) {
                            throw new Failure(409, typeName + " could not be taken out of the shared archive");
                        }
                        withdrawn.add(typeName, record);
                        origins.remove(typeName);
                        gone.add(typeName);
                    }
                    done = true;
                } finally {
                    shared.endTransaction(transaction, done);
                }
                shared.save();
                writeWithdrawn(target, withdrawn);
                writeOrigins(target, origins);
            } finally {
                shared.close();
            }
            // What this owner reads a shared type from is a copy made at start.
            if (reviewArchive != null) reviewArchive.close();
            if (reviewTypesCopy == null) reviewTypesCopy = File.createTempFile("review-types-", ".gdt");
            Files.copy(target.toPath(), reviewTypesCopy.toPath(), StandardCopyOption.REPLACE_EXISTING);
            reviewArchive = FileDataTypeManager.openFileArchive(reviewTypesCopy, false);
        }
        JsonObject answer = identity();
        answer.add("withdrawn", gone);
        answer.addProperty("reason", reason);
        answer.addProperty("kept_in_program", findAny(program.getDataTypeManager(), name, alternate) != null);
        answer.addProperty("next", "ghidra_type_uses names the functions and modules that still use it");
        return answer;
    }

    /** The names withdrawn from the shared archive, in a sidecar beside it. */
    private static File withdrawnFile(File archive) {
        return new File(archive.getPath() + ".withdrawn.json");
    }

    private JsonObject readWithdrawn() throws Failure { return readWithdrawn(reviewTypes); }

    private static JsonObject readWithdrawn(File archive) throws Failure {
        File file = withdrawnFile(archive);
        if (!file.isFile()) return new JsonObject();
        // Unreadable is refused, not read as empty: an empty list would let a
        // publish bring back every name a review withdrew.
        try (java.io.Reader reader = new java.io.InputStreamReader(new java.io.FileInputStream(file),
                                                                   java.nio.charset.StandardCharsets.UTF_8)) {
            return com.google.gson.JsonParser.parseReader(reader).getAsJsonObject();
        } catch (Exception error) {
            throw new Failure(500, file.getName() + " cannot be read: " + error.getMessage());
        }
    }

    private static void writeWithdrawn(File archive, JsonObject withdrawn) throws Exception {
        File next = new File(withdrawnFile(archive).getPath() + ".next");
        Files.writeString(next.toPath(), withdrawn.toString(), StandardCharsets.UTF_8);
        Files.move(next.toPath(), withdrawnFile(archive).toPath(), StandardCopyOption.REPLACE_EXISTING);
    }

    /** The module that last wrote each shared type, in a sidecar beside the archive. */
    private static File originFile(File archive) {
        return new File(archive.getPath() + ".origin.json");
    }

    private JsonObject readOrigins() { return readOrigins(reviewTypes); }

    private static JsonObject readOrigins(File archive) {
        File file = originFile(archive);
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

    private static void writeOrigins(File archive, JsonObject origins) {
        try (java.io.Writer writer = new java.io.OutputStreamWriter(new java.io.FileOutputStream(originFile(archive)),
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
     * when the structures differ in more than that. Asked only of two
     * equivalent types: one that is not a composite has no members to
     * compare, and only its description can be better explained.
     */
    private static int mergeComments(DataType own, DataType shared) {
        DataType ownBase = own instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : own;
        DataType sharedBase = shared instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : shared;
        int changes = 0;
        if (ownBase instanceof ghidra.program.model.data.Composite mine
            && sharedBase instanceof ghidra.program.model.data.Composite theirs) {
            if (!sameShape(mine, theirs, new java.util.HashSet<>())) return -1;
            ghidra.program.model.data.DataTypeComponent[] from = mine.getDefinedComponents();
            ghidra.program.model.data.DataTypeComponent[] to = theirs.getDefinedComponents();
            for (int i = 0; i < from.length && i < to.length; i++) {
                String comment = from[i].getComment();
                if (comment != null && !comment.isEmpty() && !comment.equals(to[i].getComment())) {
                    to[i].setComment(comment);
                    changes++;
                }
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

    /**
     * Two types the same but for comments and descriptions, at every depth:
     * `isEquivalent` follows pointers and counts a comment, so one comment on a
     * field would otherwise be a difference of everything that holds the field.
     */
    private static boolean sameShape(DataType a, DataType b, java.util.Set<String> seen) {
        if (a == null || b == null) return a == b;
        if (!seen.add(a.getPathName() + "|" + b.getPathName())) return true;
        // A typedef that only renames a function of its own name — what the C
        // parser makes of `typedef UINT32 NAME(…)` — is that function.
        if (namesItsFunction(a) && !(b instanceof ghidra.program.model.data.TypeDef)) {
            return sameShape(((ghidra.program.model.data.TypeDef) a).getBaseDataType(), b, seen);
        }
        if (namesItsFunction(b) && !(a instanceof ghidra.program.model.data.TypeDef)) {
            return sameShape(a, ((ghidra.program.model.data.TypeDef) b).getBaseDataType(), seen);
        }
        if (a instanceof ghidra.program.model.data.Pointer p && b instanceof ghidra.program.model.data.Pointer q) {
            return p.getLength() == q.getLength() && sameShape(p.getDataType(), q.getDataType(), seen);
        }
        if (a instanceof ghidra.program.model.data.Array p && b instanceof ghidra.program.model.data.Array q) {
            return p.getNumElements() == q.getNumElements() && sameShape(p.getDataType(), q.getDataType(), seen);
        }
        if (a instanceof ghidra.program.model.data.TypeDef p && b instanceof ghidra.program.model.data.TypeDef q) {
            return sameShape(p.getDataType(), q.getDataType(), seen);
        }
        if (a instanceof ghidra.program.model.data.Composite p && b instanceof ghidra.program.model.data.Composite q) {
            ghidra.program.model.data.DataTypeComponent[] left = p.getDefinedComponents();
            ghidra.program.model.data.DataTypeComponent[] right = q.getDefinedComponents();
            if (p.getClass() != q.getClass() && (p instanceof ghidra.program.model.data.Union) != (q instanceof ghidra.program.model.data.Union)) return false;
            if (p.getLength() != q.getLength() || left.length != right.length) return false;
            for (int i = 0; i < left.length; i++) {
                if (left[i].getOffset() != right[i].getOffset() || left[i].getLength() != right[i].getLength()
                    || !java.util.Objects.equals(left[i].getFieldName(), right[i].getFieldName())
                    || !sameShape(left[i].getDataType(), right[i].getDataType(), seen)) return false;
            }
            return true;
        }
        if (a instanceof ghidra.program.model.data.FunctionDefinition p && b instanceof ghidra.program.model.data.FunctionDefinition q) {
            return sameShapeIgnoringComments(p, q);
        }
        return a.isEquivalent(b);
    }

    /**
     * What this program offers the library registry
     * (`Design/LIBRARY_REGISTRY_PLAN.md`): the functions `asked` names, `{"items":
     * [{address, kind}]}`, and every function linked to an entry, whose change
     * is the entry's next version. Each is keyed by its body as Function ID
     * hashes it. A function whose review meets the bar `full` sets is an
     * `entries` item with the review the registry keeps; one short of it, or
     * with no body to key, is a `below_bar` item with its gaps. Writes nothing.
     */
    private JsonObject library() throws Exception {
        ghidra.feature.fid.service.FidService fid = new ghidra.feature.fid.service.FidService();
        JsonArray entries = new JsonArray();
        JsonArray below = new JsonArray();
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            JsonObject heldMark = libraryMark(function);
            JsonObject candidate = libraryCandidate(function);
            if (heldMark == null && candidate == null) continue;
            String kind = candidate != null ? candidate.get("kind").getAsString() : markKind(function, heldMark);
            ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(function);
            ExportCode.Assessment assessment = ExportCode.assess(
                function, decompile(function), ExportCode.stepComments(function));
            java.util.List<String> gaps = new java.util.ArrayList<>(assessment.gaps);
            if (ExportCode.bodyKey(function) == null) gaps.add("no_body");
            // Linked to an entry and not edited since: its description is the
            // entry's, and what the project lacks is no gap of anyone's.
            boolean linked = heldMark != null && atItsMark(function, hash, heldMark);
            if (linked && !gaps.isEmpty()) continue;
            if (!gaps.isEmpty()) {
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(function.getEntryPoint()));
                item.addProperty("name", function.getName());
                item.addProperty("kind", kind);
                JsonArray list = new JsonArray();
                gaps.forEach(list::add);
                item.add("gaps", list);
                libraryDependencies(function, fid, item);
                below.add(item);
                continue;
            }
            JsonObject body = new JsonObject();
            body.addProperty("size", hash.getCodeUnitSize());
            body.addProperty("full", String.format("%016x", hash.getFullHash()));
            body.addProperty("specific", String.format("%016x", hash.getSpecificHash()));
            JsonObject item = new JsonObject();
            item.addProperty("address", hex(function.getEntryPoint()));
            item.addProperty("name", function.getName());
            item.addProperty("kind", kind);
            item.add("body", body);
            JsonObject offeredEntry = libraryEntry(function, kind, body);
            if (candidate != null && candidate.has("assert_routine")) offeredEntry.addProperty("assert", true);
            item.add("entry", offeredEntry);
            if (linked) item.addProperty("linked", true);
            String offeredBytes = ExportCode.referenceBytes(function);
            if (offeredBytes != null) item.addProperty("reference_bytes", offeredBytes);
            libraryDependencies(function, fid, item);
            // A body applied as a variant of another entry says which, and
            // the assert codes that made it one.
            JsonObject mark = libraryMark(function);
            // The version this review was made on: a change on the entry's
            // current version is its next one, from any module.
            if (mark != null) {
                item.addProperty("based_on", mark.get("id").getAsString());
                item.add("base", mark.get("version"));
            }
            if (mark != null && hash.getCodeUnitSize() >= 4 && !mark.get("id").getAsString().equals(bodyKey(hash))) {
                item.addProperty("variant_of", mark.get("id").getAsString());
                if (mark.has("codes")) item.add("codes", mark.get("codes"));
            }
            entries.add(item);
        }
        JsonObject answer = identity();
        answer.add("entries", entries);
        answer.add("below_bar", below);
        return answer;
    }

    /**
     * What the body names outside itself and the stack: a reference to memory
     * that is not a call or a jump, or a constant that lands in the image — a
     * `PUSH imm32` of a GUID's address, or `MOV EAX,imm; CALL EAX`, carries no
     * reference until something makes one. An address where an instruction
     * starts is code, an indirect callee; any other is data, by the offset that
     * names it. A small constant in an image based at zero is not taken for an
     * address. It errs towards naming: a doubt keeps a function in its module.
     */
    private void libraryOutside(Function function, java.util.Set<String> data, java.util.Set<Address> code) {
        Address entry = function.getEntryPoint();
        boolean baseIsReal = program.getImageBase().getOffset() >= 0x10000;
        ghidra.program.model.listing.Listing listing = program.getListing();
        ghidra.program.model.listing.InstructionIterator instructions = listing.getInstructions(function.getBody(), true);
        while (instructions.hasNext()) {
            ghidra.program.model.listing.Instruction instruction = instructions.next();
            java.util.List<Address> named = new java.util.ArrayList<>();
            for (ghidra.program.model.symbol.Reference reference : instruction.getReferencesFrom()) {
                if (reference.isStackReference() || reference.getReferenceType().isFlow()) continue;
                named.add(reference.getToAddress());
            }
            if (baseIsReal) {
                for (int operand = 0; operand < instruction.getNumOperands(); operand++) {
                    for (Object part : instruction.getOpObjects(operand)) {
                        if (!(part instanceof ghidra.program.model.scalar.Scalar scalar)) continue;
                        try {
                            named.add(entry.getNewAddress(scalar.getUnsignedValue()));
                        } catch (Exception error) {
                            // Not an address of this space.
                        }
                    }
                }
            }
            for (Address to : named) {
                if (!to.isMemoryAddress() || !program.getMemory().contains(to) || function.getBody().contains(to)) continue;
                if (listing.getInstructionAt(to) != null) code.add(to);
                else data.add(String.format("0x%X", instruction.getAddress().subtract(entry)));
            }
        }
    }

    /** What decides whether a function depends on a module: `data_references` and `callees`, beside the review. */
    private void libraryDependencies(Function function, ghidra.feature.fid.service.FidService fid, JsonObject item)
            throws Exception {
        java.util.Set<String> data = new java.util.LinkedHashSet<>();
        java.util.Set<Address> code = new java.util.LinkedHashSet<>();
        libraryOutside(function, data, code);
        JsonArray references = new JsonArray();
        data.forEach(references::add);
        item.add("data_references", references);
        JsonArray callees = new JsonArray();
        java.util.Set<Function> called = new java.util.LinkedHashSet<>(
            function.getCalledFunctions(ghidra.util.task.TaskMonitor.DUMMY));
        for (Address to : code) {
            Function target = program.getFunctionManager().getFunctionAt(to);
            if (target != null) {
                called.add(target);
            } else {
                JsonObject unknown = new JsonObject();
                unknown.addProperty("name", "code at " + hex(to));
                callees.add(unknown);
            }
        }
        for (Function each : called) {
            Function target = each.isThunk() ? each.getThunkedFunction(true) : each;
            JsonObject callee = new JsonObject();
            callee.addProperty("name", target.getName());
            ghidra.feature.fid.hash.FidHashQuad hash = target.isExternal() ? null : ExportCode.bodyHash(target);
            // A short body's bytes name no entry: the mark does.
            JsonObject calleeMark = hash != null && hash.getCodeUnitSize() < 4 ? libraryMark(target) : null;
            if (calleeMark != null) callee.addProperty("body", calleeMark.get("id").getAsString());
            else if (hash != null) callee.addProperty("body", bodyKey(hash));
            callees.add(callee);
        }
        item.add("callees", callees);
    }

    /**
     * One function's review as the registry keeps it: nothing that names this
     * module — no address, no module — so the same review of the same body in
     * another module is the same entry. Comments are placed by their offset
     * from the entry, variables by their storage.
     */
    private JsonObject libraryEntry(Function function, String kind, JsonObject body) {
        return libraryEntry(function, kind, body, true);
    }

    /**
     * What the listing alone says of a review, for the digest a mark keeps:
     * does the function read otherwise than when the mark was written? Cheap
     * on purpose — a status call asks it for every match, and the listing's
     * names and types are the ones a review writes.
     */
    private JsonObject libraryEntryListing(Function function, String kind, JsonObject body) {
        return libraryEntry(function, kind, body, false);
    }

    /**
     * One function's review as the registry keeps it. The locals are the
     * decompiled C's, not the listing's: the listing holds stack slots the C
     * never mentions, and a local's type in the listing may be `undefined4`
     * where the decompiler reads it as `UINT32`. Between them the two would
     * put a review in the registry that no module shows.
     */
    private JsonObject libraryEntry(Function function, String kind, JsonObject body, boolean decompiler) {
        Address entry = function.getEntryPoint();
        JsonObject answer = new JsonObject();
        answer.addProperty("schema", 1);
        answer.add("body", body);
        answer.addProperty("kind", kind);
        answer.addProperty("name", function.getName());
        answer.addProperty("signature", function.getPrototypeString(false, false));
        answer.addProperty("calling_convention", function.getCallingConventionName());
        answer.addProperty("return_type", function.getReturnType().getDisplayName());
        JsonArray parameters = new JsonArray();
        for (Parameter parameter : function.getParameters()) {
            JsonObject item = new JsonObject();
            item.addProperty("ordinal", parameter.getOrdinal());
            item.addProperty("storage", parameter.getVariableStorage().toString());
            item.addProperty("name", parameter.getName());
            item.addProperty("type", parameter.getDataType().getDisplayName());
            parameters.add(item);
        }
        answer.add("params", parameters);
        // The locals the C shows, by the place the program stores them: the
        // decompiler's name and type for a stored variable, and nothing for a
        // slot the C never reads.
        java.util.Map<String, HighSymbol> shown = new java.util.HashMap<>();
        if (decompiler) {
            DecompileResults results = decompile(function);
            HighFunction high = results == null ? null : results.getHighFunction();
            if (high != null) {
                Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
                while (symbols.hasNext()) {
                    HighSymbol symbol = symbols.next();
                    if (symbol.isParameter()) continue;
                    if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
                    if (unshared(symbol.getStorage())) continue;
                    Address pc = symbol.getPCAddress();
                    long firstUse = pc == null ? -1 : pc.subtract(entry);
                    shown.put(place(symbol.getStorage(), firstUse), symbol);
                }
            }
        }
        java.util.TreeMap<String, JsonObject> locals = new java.util.TreeMap<>();
        for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
            // A decompiler temporary (`HASH:…`, `unique:…`) is named by a hash
            // of the module's own p-code: no other module has a place for it,
            // so it is the module's, not the entry's.
            ghidra.program.model.listing.VariableStorage held = local.getVariableStorage();
            if (held.isHashStorage() || held.isUniqueStorage()) continue;
            String key = place(held, local.getFirstUseOffset());
            HighSymbol symbol = decompiler ? shown.get(key) : null;
            if (decompiler && symbol == null) continue;
            JsonObject item = new JsonObject();
            item.addProperty("storage", held.toString());
            item.addProperty("first_use", String.format("0x%X", local.getFirstUseOffset()));
            item.addProperty("name", symbol == null ? local.getName() : symbol.getName());
            DataType type = symbol == null ? local.getDataType() : symbol.getDataType();
            item.addProperty("type", type == null ? "undefined" : type.getDisplayName());
            locals.put(key, item);
        }
        JsonArray localList = new JsonArray();
        locals.values().forEach(localList::add);
        answer.add("locals", localList);
        String plate = function.getComment();
        answer.addProperty("plate", plate == null ? "" : plate);
        JsonArray comments = new JsonArray();
        ghidra.program.model.listing.InstructionIterator code =
            program.getListing().getInstructions(function.getBody(), true);
        while (code.hasNext()) {
            ghidra.program.model.listing.Instruction instruction = code.next();
            for (CommentType type : new CommentType[] { CommentType.PRE, CommentType.EOL, CommentType.POST }) {
                String text = instruction.getComment(type);
                if (text == null || text.isBlank()) continue;
                JsonObject item = new JsonObject();
                item.addProperty("offset", String.format("0x%X", instruction.getAddress().subtract(entry)));
                item.addProperty("kind", type.name().toLowerCase());
                item.addProperty("text", text);
                comments.add(item);
            }
        }
        answer.add("comments", comments);
        answer.add("constants", constants(function));
        // An assert routine: the codes it is called with make variants of
        // the entries that call it, not functions of their own.
        if (hasTag(function, ASSERT_TAG)) answer.addProperty("assert", true);
        return answer;
    }

    // MARK: - The library registry: matching and applying (LIBRARY_REGISTRY_PLAN.md §4)

    /** Where a function applied from the registry keeps its entry: id, version, the digest of what was applied, codes. */
    static final String LIBRARY_MARK = "ByteRipper.libraryEntry";
    /** A function a review proposes for the registry: the project's, until a publish decides it. */
    static final String LIBRARY_CANDIDATE = "ByteRipper.libraryCandidate";
    /** The entries a review declined for a function, by id, comma-separated. */
    static final String LIBRARY_DECLINED = "ByteRipper.libraryDeclined";
    /** Whose library a registry entry can say it is. */
    static final java.util.List<String> LIBRARY_KINDS = java.util.List.of("edk2", "amd", "intel");
    /** The tag of an assert routine: the codes it is called with make variants, not functions. */
    static final String ASSERT_TAG = "assert_routine";
    private static final Gson COMPACT = new GsonBuilder().disableHtmlEscaping().create();

    private static boolean hasTag(Function function, String name) {
        for (ghidra.program.model.listing.FunctionTag tag : function.getTags()) {
            if (tag != null && tag.getName().equalsIgnoreCase(name)) return true;
        }
        return false;
    }

    /** `<size>-<full>-<specific>`, as the store keys a body (`LibraryBody.key`). */
    private static String bodyKey(ghidra.feature.fid.hash.FidHashQuad hash) {
        return Integer.toHexString(hash.getCodeUnitSize()) + "-" + String.format("%016x", hash.getFullHash())
            + "-" + String.format("%016x", hash.getSpecificHash());
    }

    private static String shapeKey(ghidra.feature.fid.hash.FidHashQuad hash) {
        return Integer.toHexString(hash.getCodeUnitSize()) + "-" + String.format("%016x", hash.getFullHash());
    }

    private static JsonObject bodyObject(ghidra.feature.fid.hash.FidHashQuad hash) {
        JsonObject body = new JsonObject();
        body.addProperty("size", hash.getCodeUnitSize());
        body.addProperty("full", String.format("%016x", hash.getFullHash()));
        body.addProperty("specific", String.format("%016x", hash.getSpecificHash()));
        return body;
    }

    /**
     * The values the body's instructions hold that are not addresses, in
     * order: what Function ID's specific hash keeps and its full hash masks.
     * Two bodies of one shape differ only here.
     */
    private JsonArray constants(Function function) {
        JsonArray list = new JsonArray();
        Address entry = function.getEntryPoint();
        InstructionIterator code = program.getListing().getInstructions(function.getBody(), true);
        while (code.hasNext()) {
            Instruction instruction = code.next();
            for (int operand = 0; operand < instruction.getNumOperands(); operand++) {
                if (instruction.getOperandReferences(operand).length > 0) continue;
                for (Object part : instruction.getOpObjects(operand)) {
                    if (!(part instanceof ghidra.program.model.scalar.Scalar scalar)) continue;
                    JsonObject item = new JsonObject();
                    item.addProperty("offset", String.format("0x%X", instruction.getAddress().subtract(entry)));
                    item.addProperty("operand", operand);
                    item.addProperty("value", String.format("0x%X", scalar.getUnsignedValue()));
                    list.add(item);
                }
            }
        }
        return list;
    }

    /** The registry mark of a function, or null: `{id, version, digest, codes?}`. */
    private JsonObject libraryMark(Function function) {
        StringPropertyMap marks = program.getUsrPropertyManager().getStringPropertyMap(LIBRARY_MARK);
        String text = marks == null ? null : marks.getString(function.getEntryPoint());
        if (text == null || text.isBlank()) return null;
        try {
            return JsonParser.parseString(text).getAsJsonObject();
        } catch (Exception error) {
            return null;
        }
    }

    /** Whose library the entry a function links to is, as its mark keeps it. */
    private static String markKind(Function function, JsonObject mark) {
        if (mark != null && mark.has("kind")) return mark.get("kind").getAsString();
        // A mark from before the kind was on it: the kind is on the tag until
        // the next publish retires it.
        for (ghidra.program.model.listing.FunctionTag tag : function.getTags()) {
            String name = tag == null ? "" : tag.getName().toLowerCase(java.util.Locale.ROOT);
            if (name.startsWith("library.")) return name.substring(8);
        }
        return "";
    }

    private java.util.List<String> declined(Function function) {
        StringPropertyMap map = program.getUsrPropertyManager().getStringPropertyMap(LIBRARY_DECLINED);
        String text = map == null ? null : map.getString(function.getEntryPoint());
        java.util.List<String> ids = new java.util.ArrayList<>();
        if (text != null) for (String id : text.split(",")) if (!id.isBlank()) ids.add(id.trim());
        return ids;
    }

    /**
     * What the function's review is now, as one digest: the entry it would
     * offer the registry. The mark keeps the digest of what was applied, so
     * a function edited since is told from one that is not.
     */
    private String reviewDigest(Function function, ghidra.feature.fid.hash.FidHashQuad hash) throws Exception {
        JsonObject entry = libraryEntryListing(function, markKind(function, libraryMark(function)), bodyObject(hash));
        byte[] bytes = COMPACT.toJson(entry).getBytes(StandardCharsets.UTF_8);
        return hexBytes(java.security.MessageDigest.getInstance("SHA-256").digest(bytes)).replace(" ", "");
    }

    /**
     * `POST /v1/library/match`: every function hashed once, against the
     * registry's bodies (`{"bodies": {key: id}}`) and shapes (`{"shapes":
     * {size-full: [id]}}`). Answers the functions with an exact body, a body
     * of a known shape, or a registry mark — each with its name and whether a
     * review named it, the mark and whether the function was edited since,
     * and the entries a review declined for it. Nothing is written.
     */
    private JsonObject libraryMatch(JsonObject body) throws Exception {
        JsonObject bodies = body.has("bodies") ? body.getAsJsonObject("bodies") : new JsonObject();
        JsonObject shapes = body.has("shapes") ? body.getAsJsonObject("shapes") : new JsonObject();
        ghidra.feature.fid.service.FidService fid = new ghidra.feature.fid.service.FidService();
        JsonArray matches = new JsonArray();
        int hashed = 0;
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            if (function.isThunk() || function.isExternal()) continue;
            ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(function);
            if (hash == null) continue;
            hashed++;
            String key = bodyKey(hash);
            JsonObject mark = libraryMark(function);
            JsonElement exact = bodies.get(key);
            JsonElement near = exact == null ? shapes.get(shapeKey(hash)) : null;
            if (exact == null && near == null && mark == null) continue;
            JsonObject item = new JsonObject();
            item.addProperty("address", hex(function.getEntryPoint()));
            item.addProperty("name", function.getName());
            item.addProperty("named", function.getSymbol().getSource() == SourceType.USER_DEFINED);
            item.addProperty("key", key);
            if (exact != null) item.add("exact", exact);
            if (near != null) item.add("near", near);
            String bytes = ExportCode.referenceBytes(function);
            if (bytes != null) item.addProperty("reference_bytes", bytes);
            if (mark != null) {
                JsonObject held = mark.deepCopy();
                held.addProperty("edited", !atItsMark(function, hash, mark));
                held.remove("dirty");
                held.remove("written");
                held.remove("digest");
                item.add("mark", held);
            }
            JsonArray refused = new JsonArray();
            declined(function).forEach(refused::add);
            if (refused.size() > 0) item.add("declined", refused);
            matches.add(item);
        }
        JsonObject answer = identity();
        answer.addProperty("hashed", hashed);
        answer.add("matches", matches);
        return answer;
    }

    /**
     * `POST /v1/library/compare`: the function at `address` against an
     * entry of its shape, constant by constant. Each value that differs is
     * listed with the entry's, and called an assert code when the
     * instruction hands it to an assert routine — a `PUSH` or a `MOV` into a
     * register, followed within a few instructions, with no branch between,
     * by a call to a function whose body is one of `assert_keys` or whose
     * mark is one of `assert_ids`. Nothing is written.
     */
    private JsonObject libraryCompare(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        JsonObject entry = body.getAsJsonObject("entry");
        java.util.Set<String> assertKeys = new java.util.HashSet<>();
        java.util.Set<String> assertIds = new java.util.HashSet<>();
        if (body.has("assert_keys")) body.getAsJsonArray("assert_keys").forEach(e -> assertKeys.add(e.getAsString()));
        if (body.has("assert_ids")) body.getAsJsonArray("assert_ids").forEach(e -> assertIds.add(e.getAsString()));
        JsonObject answer = identity();
        answer.addProperty("address", hex(function.getEntryPoint()));
        JsonArray theirs = entry == null || !entry.has("constants") ? null : entry.getAsJsonArray("constants");
        JsonArray ours = constants(function);
        if (theirs == null || theirs.size() != ours.size()) {
            answer.addProperty("comparable", false);
            answer.addProperty("why", theirs == null ? "the entry holds no constants: publish its module again"
                                                     : "the bodies hold different numbers of constants");
            return answer;
        }
        ghidra.feature.fid.service.FidService fid = new ghidra.feature.fid.service.FidService();
        JsonArray differences = new JsonArray();
        boolean allAssert = true;
        for (int index = 0; index < ours.size(); index++) {
            JsonObject own = ours.get(index).getAsJsonObject(), other = theirs.get(index).getAsJsonObject();
            if (!own.get("offset").equals(other.get("offset")) || !own.get("operand").equals(other.get("operand"))) {
                answer.addProperty("comparable", false);
                answer.addProperty("why", "the constants sit at other places");
                return answer;
            }
            if (own.get("value").equals(other.get("value"))) continue;
            Address at = function.getEntryPoint().add(relative(own.get("offset").getAsString()));
            boolean code = assertArgument(program.getListing().getInstructionAt(at), assertKeys, assertIds, fid);
            allAssert &= code;
            JsonObject item = own.deepCopy();
            item.addProperty("entry_value", other.get("value").getAsString());
            item.addProperty("assert", code);
            differences.add(item);
        }
        answer.addProperty("comparable", true);
        answer.add("differences", differences);
        answer.addProperty("assert_codes_only", differences.size() > 0 && allAssert);
        return answer;
    }

    private boolean assertArgument(Instruction instruction, java.util.Set<String> keys, java.util.Set<String> ids,
                                   ghidra.feature.fid.service.FidService fid) throws Exception {
        if (instruction == null) return false;
        String mnemonic = instruction.getMnemonicString().toUpperCase(java.util.Locale.ROOT);
        boolean argument = mnemonic.equals("PUSH")
            || (mnemonic.equals("MOV") && instruction.getRegister(0) != null);
        if (!argument) return false;
        Instruction next = instruction.getNext();
        for (int step = 0; step < 6 && next != null; step++, next = next.getNext()) {
            ghidra.program.model.symbol.FlowType flow = next.getFlowType();
            if (flow.isCall()) {
                Address[] targets = next.getFlows();
                if (targets.length != 1) return false;
                Function callee = program.getFunctionManager().getFunctionAt(targets[0]);
                if (callee == null) return false;
                JsonObject mark = libraryMark(callee);
                if (mark != null && ids.contains(mark.get("id").getAsString())) return true;
                ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(callee);
                return hash != null && keys.contains(bodyKey(hash));
            }
            if (flow.isJump() || flow.isTerminal()) return false;
        }
        return false;
    }

    /**
     * `POST /v1/library/apply`: registry entries applied, `{"items": [{address,
     * id, version, entry, mode, reason?, codes?}]}`, each in a transaction of
     * its own. `mode` is `whole` — the entry's name, signature, variables,
     * plate, comments and tag replace the function's: a function no review
     * named, one applied before and not edited since, or one the agent asked
     * to replace — or `fill`: a function a review named takes the entry's
     * name, the old one kept in the reason, and only what its review left
     * empty; where the review says otherwise, the item lists the difference
     * and keeps the review's. A function left equal to the entry carries
     * the mark (`ByteRipper.libraryEntry`). A name another item's function
     * still holds is tried again once that one is renamed — two modules that
     * named a pair of routines the other way round converge.
     */
    private JsonObject libraryApply(HttpExchange exchange) throws Exception {
        requireLease(exchange);
        JsonObject body = body(exchange);
        // `dry_run`: each entry applied in its transaction and rolled back —
        // the answer is what the apply would do, and the program keeps what it
        // had. A preview of a large review costs one transaction per entry.
        java.util.Map<String, String> parameters = query(exchange.getRequestURI().getRawQuery());
        boolean dryRun = "1".equals(parameters.get("dry_run"))
            || (body.has("dry_run") && !body.get("dry_run").isJsonNull() && body.get("dry_run").getAsBoolean());
        JsonArray items = body.has("items") ? body.getAsJsonArray("items") : new JsonArray();
        java.util.List<JsonObject> pending = new java.util.ArrayList<>();
        items.forEach(e -> pending.add(e.getAsJsonObject()));
        java.util.Map<JsonObject, JsonObject> answers = new java.util.IdentityHashMap<>();
        boolean progress = true;
        while (!pending.isEmpty() && progress) {
            progress = false;
            for (Iterator<JsonObject> it = pending.iterator(); it.hasNext();) {
                JsonObject item = it.next();
                long before = program.getModificationNumber();
                int transaction = program.startTransaction("library apply");
                boolean done = false;
                JsonObject answer;
                try {
                    answer = applyEntry(item);
                    answer.addProperty("ok", true);
                    done = true;
                } catch (Failure failure) {
                    answer = new JsonObject();
                    answer.addProperty("address", string(item, "address", ""));
                    answer.addProperty("id", string(item, "id", ""));
                    answer.addProperty("ok", false);
                    answer.addProperty("error", failure.getMessage());
                    answer.addProperty("name_taken", failure.status == 409);
                } catch (Exception error) {
                    answer = new JsonObject();
                    answer.addProperty("address", string(item, "address", ""));
                    answer.addProperty("id", string(item, "id", ""));
                    answer.addProperty("ok", false);
                    answer.addProperty("error", error.toString());
                } finally {
                    endTransaction(transaction, done && !dryRun, before);
                }
                answers.put(item, answer);
                if (done) { it.remove(); progress = true; }
                else if (!(answer.has("name_taken") && answer.get("name_taken").getAsBoolean())) it.remove();
            }
        }
        JsonArray list = new JsonArray();
        for (JsonElement element : items) list.add(answers.get(element.getAsJsonObject()));
        System.out.println("OWNER LIBRARY APPLY " + leaseHolder + " " + list.size());
        JsonObject answer = identity();
        answer.addProperty("dry_run", dryRun);
        answer.add("items", list);
        return answer;
    }

    private JsonObject applyEntry(JsonObject item) throws Exception {
        Function function = program.getFunctionManager().getFunctionAt(address(required(item, "address")));
        if (function == null) throw new Failure(404, "no function starts at " + required(item, "address"));
        String id = required(item, "id");
        int version = integer(item, "version", 1);
        JsonObject entry = item.getAsJsonObject("entry");
        if (entry == null) throw new Failure(400, "the item holds no entry");
        String mode = string(item, "mode", "link");
        // The function is bound to the entry: it takes the name and the signature
        // its callers print, and what the project holds stays, which is the
        // review's own. `whole` and `variant` put the entry's text in its place,
        // for a review that goes on writing over it.
        boolean link = mode.equals("link");
        String reason = "library registry entry " + id;
        if (item.has("reason") && !item.get("reason").isJsonNull()) reason += ": " + item.get("reason").getAsString();
        JsonArray filled = new JsonArray(), differences = new JsonArray(), unplaced = new JsonArray();
        JsonObject answer = new JsonObject();
        answer.addProperty("address", hex(function.getEntryPoint()));
        answer.addProperty("id", id);
        answer.addProperty("version", version);
        answer.addProperty("mode", mode);
        String oldName = function.getName();
        String name = required(entry, "name");
        Address at = function.getEntryPoint();
        if (!oldName.equals(name)) {
            for (Symbol other : program.getSymbolTable().getGlobalSymbols(name)) {
                if (!other.getAddress().equals(function.getEntryPoint())) {
                    throw new Failure(409, name + " already names " + hex(other.getAddress()));
                }
            }
            function.setName(name, SourceType.USER_DEFINED);
            JsonObject renamed = new JsonObject();
            renamed.addProperty("from", oldName);
            renamed.addProperty("to", name);
            answer.add("renamed", renamed);
        }
        JsonObject why = new JsonObject();
        why.addProperty("reason", oldName.equals(name) ? reason : reason + " (was " + oldName + ")");
        why.addProperty("by", "agent");
        if (!sameSignature(function, entry)) {
            applySignature(function, entry, why);
            filled.add("signature");
        }
        why(at, why);
        if (!link) {
            applyLocals(function, entry, true, filled, differences, unplaced);
            String plate = string(entry, "plate", "");
            function.setComment(plate.isEmpty() ? null : plate);
            filled.add("plate");
            applyComments(function, entry, true, filled, differences, unplaced);
            applyEntryEquates(function, entry, differences);
        }
        String kind = string(entry, "kind", "");
        if (entry.has("assert") && entry.get("assert").getAsBoolean() && !hasTag(function, ASSERT_TAG)) {
            function.addTag(ASSERT_TAG);
        }
        decompiled.remove(function.getEntryPoint());
        if (item.has("leftovers") && item.get("leftovers").getAsBoolean()) {
            ExportCode.Assessment after = ExportCode.assess(
                function, decompile(function), ExportCode.stepComments(function));
            if (!after.gaps.isEmpty()) {
                JsonArray left = new JsonArray();
                after.gaps.forEach(left::add);
                answer.add("leftovers", left);
            }
        }
        ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(function);
        JsonObject mark = new JsonObject();
        mark.addProperty("id", id);
        mark.addProperty("version", version);
        mark.addProperty("kind", kind);
        if (item.has("codes")) mark.add("codes", item.get("codes"));
        propertyMap(LIBRARY_MARK).add(function.getEntryPoint(), COMPACT.toJson(mark));
        if (hash != null) {
            mark.addProperty("digest", reviewDigest(function, hash));
            propertyMap(LIBRARY_MARK).add(function.getEntryPoint(), COMPACT.toJson(mark));
        }
        answer.addProperty("marked", true);
        if (filled.size() > 0) answer.add("filled", filled);
        if (differences.size() > 0) answer.add("differences", differences);
        if (unplaced.size() > 0) answer.add("unplaced", unplaced);
        return answer;
    }

    /**
     * The names the entry's C prints, so an edit made on its text does not drop
     * them. An operand this project already names keeps its own name: that one
     * is what its next change offers, and the reason answers for it.
     */
    private void applyEntryEquates(Function function, JsonObject entry, JsonArray differences) {
        if (!entry.has("equates")) return;
        ghidra.program.model.symbol.EquateTable table = program.getEquateTable();
        for (JsonElement element : entry.getAsJsonArray("equates")) {
            JsonObject equate = element.getAsJsonObject();
            for (JsonElement place : equate.getAsJsonArray("uses")) {
                JsonArray use = place.getAsJsonArray();
                try {
                    Address at = function.getEntryPoint().add(Long.decode(use.get(0).getAsString()));
                    int operand = use.get(1).getAsInt();
                    boolean named = false;
                    for (ghidra.program.model.symbol.Equate own : table.getEquates(at, operand)) named = true;
                    if (named) continue;
                    JsonObject one = equate.deepCopy();
                    one.remove("uses");
                    one.addProperty("address", hex(at));
                    one.addProperty("operand", operand);
                    applyEquate(one);
                } catch (Exception error) {
                    differences.add("equate " + string(equate, "name", "") + ": " + error.getMessage());
                }
            }
        }
    }

    private static JsonObject review(JsonObject entry) {
        JsonObject copy = entry.deepCopy();
        copy.remove("body");
        copy.remove("constants");
        // The function as it read when it was recorded: no part of the review.
        copy.remove("function");
        // What its C prints, recorded with it from the same reading.
        copy.remove("equates");
        return copy;
    }

    /**
     * Where a local lives, as the two readings spell it: a stack slot is one
     * variable and has no first use of its own — the program writes -1 and the
     * decompiler gives the address of the first use — so the slot alone names
     * it; a register may hold several in a function, and the first use tells
     * them apart.
     */
    private static String place(ghidra.program.model.listing.VariableStorage storage, long firstUse) {
        String place = storage.toString();
        return place.startsWith("Stack") ? place : place + "@" + firstUse;
    }

    /** A storage in the decompiler's own space — a hash or unique address — is not a module's. */
    private static boolean unshared(ghidra.program.model.listing.VariableStorage storage) {
        if (storage == null) return false;
        if (storage.isHashStorage() || storage.isUniqueStorage()) return true;
        for (ghidra.program.model.pcode.Varnode piece : storage.getVarnodes()) {
            if (piece.getAddress().getAddressSpace().getType()
                    == ghidra.program.model.address.AddressSpace.TYPE_UNIQUE) return true;
        }
        return false;
    }

    /** The function's signature, convention and parameter storage are the entry's already. */
    /**
     * The convention an entry names, if it names one. An entry whose function
     * analysis left at `unknown` says nothing about the convention, and writing
     * that onto another module's function would put the decompiler's warning there.
     */
    private static String namedConvention(JsonObject entry) {
        String convention = string(entry, "calling_convention", null);
        return "unknown".equals(convention) ? null : convention;
    }

    private static boolean sameSignature(Function function, JsonObject entry) {
        if (!function.getPrototypeString(false, false).equals(string(entry, "signature", null))) return false;
        // An entry recorded before a storage dropped the convention still names
        // it: the storage below decides, and applying it again would change nothing.
        boolean dropped = function.hasCustomVariableStorage()
            && function.getCallingConventionName().equals(Function.DEFAULT_CALLING_CONVENTION_STRING);
        String wanted = namedConvention(entry);
        if (!dropped && wanted != null && !function.getCallingConventionName().equals(wanted)) return false;
        JsonArray params = entry.has("params") ? entry.getAsJsonArray("params") : new JsonArray();
        Parameter[] current = function.getParameters();
        if (params.size() != current.length) return false;
        for (int index = 0; index < current.length; index++) {
            String place = params.get(index).getAsJsonObject().get("storage").getAsString();
            if (!current[index].getVariableStorage().toString().equals(place)) return false;
        }
        return true;
    }

    private void applySignature(Function function, JsonObject entry, JsonObject why) throws Exception {
        JsonObject request = why.deepCopy();
        request.addProperty("address", hex(function.getEntryPoint()));
        request.addProperty("signature", required(entry, "signature"));
        setSignature(request);
        String convention = namedConvention(entry);
        if (convention != null && !convention.equals(function.getCallingConventionName())) {
            function.setCallingConvention(convention);
        }
        JsonArray params = entry.has("params") ? entry.getAsJsonArray("params") : new JsonArray();
        Parameter[] current = function.getParameters();
        if (params.size() != current.length) {
            throw new Failure(400, "the signature gave " + current.length + " parameters, the entry lists "
                              + params.size());
        }
        boolean moved = false;
        JsonArray storage = new JsonArray();
        for (int index = 0; index < current.length; index++) {
            String place = params.get(index).getAsJsonObject().get("storage").getAsString();
            storage.add(place);
            if (!current[index].getVariableStorage().toString().equals(place)) moved = true;
        }
        if (moved) {
            JsonObject places = new JsonObject();
            places.add("storage", storage);
            applyStorage(function, places);
        }
    }

    private void applyLocals(Function function, JsonObject entry, boolean whole, JsonArray filled,
                             JsonArray differences, JsonArray unplaced) throws Exception {
        JsonArray locals = entry.has("locals") ? entry.getAsJsonArray("locals") : new JsonArray();
        if (whole) {
            // The entry's review is the function's: a local it does not name
            // is the old review's, and stays nowhere.
            java.util.Set<String> kept = new java.util.HashSet<>();
            for (JsonElement element : locals) {
                JsonObject theirs = element.getAsJsonObject();
                kept.add(theirs.get("storage").getAsString() + "@"
                         + relative(theirs.get("first_use").getAsString()));
            }
            for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
                ghidra.program.model.listing.VariableStorage held = local.getVariableStorage();
                if (held.isHashStorage() || held.isUniqueStorage()) continue;
                if (kept.contains(held.toString() + "@" + local.getFirstUseOffset())) continue;
                filled.add("removed local " + local.getName());
                function.removeVariable(local);
            }
        }
        for (JsonElement element : locals) {
            JsonObject theirs = element.getAsJsonObject();
            String place = theirs.get("storage").getAsString(), name = theirs.get("name").getAsString();
            int firstUse = (int) relative(theirs.get("first_use").getAsString());
            DataType type;
            try {
                type = type(theirs.get("type").getAsString());
            } catch (Failure failure) {
                unplaced.add("local " + name + ": " + failure.getMessage());
                continue;
            }
            ghidra.program.model.listing.Variable held = null;
            for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
                if (local.getVariableStorage().toString().equals(place) && local.getFirstUseOffset() == firstUse) {
                    held = local;
                }
            }
            try {
                if (held == null) {
                    function.addLocalVariable(new ghidra.program.model.listing.LocalVariableImpl(
                        name, firstUse, type, storage(place, type.getLength()), program), SourceType.USER_DEFINED);
                    filled.add("local " + name);
                    continue;
                }
                boolean sameName = held.getName().equals(name);
                boolean sameType = held.getDataType().getDisplayName().equals(type.getDisplayName());
                if (sameName && sameType) continue;
                boolean ownName = !placeholder(held.getName()), ownType = !undefined(held.getDataType());
                if (!sameName && (whole || !ownName)) held.setName(name, SourceType.USER_DEFINED);
                else if (!sameName) differences.add("local " + held.getName() + ": entry " + name);
                if (!sameType && (whole || !ownType)) held.setDataType(type, SourceType.USER_DEFINED);
                else if (!sameType) differences.add("local " + held.getName() + " type: entry " + type.getDisplayName());
                if ((!sameName && (whole || !ownName)) || (!sameType && (whole || !ownType))) filled.add("local " + name);
            } catch (Failure failure) {
                unplaced.add("local " + name + " at " + place + ": " + failure.getMessage());
            } catch (Exception error) {
                unplaced.add("local " + name + " at " + place + ": " + error.getMessage());
            }
        }
    }

    private void applyComments(Function function, JsonObject entry, boolean whole, JsonArray filled,
                               JsonArray differences, JsonArray unplaced) throws Exception {
        Address start = function.getEntryPoint();
        if (whole) {
            // A version's comments replace the last one's: none is left behind.
            InstructionIterator code = program.getListing().getInstructions(function.getBody(), true);
            while (code.hasNext()) {
                Instruction instruction = code.next();
                for (CommentType type : new CommentType[] { CommentType.PRE, CommentType.EOL, CommentType.POST }) {
                    instruction.setComment(type, null);
                }
            }
        }
        JsonArray comments = entry.has("comments") ? entry.getAsJsonArray("comments") : new JsonArray();
        int set = 0, differ = 0;
        for (JsonElement element : comments) {
            JsonObject theirs = element.getAsJsonObject();
            Address at = start.add(relative(theirs.get("offset").getAsString()));
            Instruction instruction = program.getListing().getInstructionAt(at);
            if (instruction == null || !function.getBody().contains(at)) {
                unplaced.add("comment at " + theirs.get("offset").getAsString());
                continue;
            }
            CommentType type = CommentType.valueOf(theirs.get("kind").getAsString().toUpperCase(java.util.Locale.ROOT));
            String text = theirs.get("text").getAsString(), own = instruction.getComment(type);
            if (own == null || own.isBlank()
                    || ExportCode.writtenByAnalysis(at, type.name().toLowerCase(java.util.Locale.ROOT), own)) {
                instruction.setComment(type, text);
                set++;
            } else if (!own.equals(text)) {
                differ++;
            }
        }
        if (set > 0) filled.add(set + " comments");
        if (differ > 0) differences.add(differ + " comments");
    }

    /**
     * `POST /v1/library/mark`: after a publish, the functions the registry
     * took or matched carry the version it holds now — `{"items": [{address,
     * id, version}]}` — so the next change to one is made on that version.
     * A function's codes stay when it keeps its entry.
     */
    private JsonObject libraryMarkAll(JsonObject body) throws Exception {
        JsonArray items = body.has("items") ? body.getAsJsonArray("items") : new JsonArray();
        ghidra.feature.fid.service.FidService fid = new ghidra.feature.fid.service.FidService();
        int marked = 0, changed = 0;
        for (JsonElement element : items) {
            JsonObject item = element.getAsJsonObject();
            Function function = program.getFunctionManager().getFunctionAt(address(required(item, "address")));
            if (function == null) continue;
            String before = libraryState(function);
            String id = required(item, "id");
            ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(function);
            if (hash == null) continue;
            JsonObject held = libraryMark(function);
            JsonObject mark = new JsonObject();
            mark.addProperty("id", id);
            mark.addProperty("version", integer(item, "version", 1));
            mark.addProperty("kind", string(item, "kind", markKind(function, held)));
            // The registry took it: it is no candidate now.
            JsonObject candidate = libraryCandidate(function);
            if (candidate != null) {
                if (candidate.has("assert_routine")) function.addTag(ASSERT_TAG);
                propertyMap(LIBRARY_CANDIDATE).remove(function.getEntryPoint());
            }
            propertyMap(LIBRARY_MARK).add(function.getEntryPoint(), COMPACT.toJson(mark));
            mark.addProperty("digest", reviewDigest(function, hash));
            if (held != null && id.equals(string(held, "id", "")) && held.has("codes")) mark.add("codes", held.get("codes"));
            propertyMap(LIBRARY_MARK).add(function.getEntryPoint(), COMPACT.toJson(mark));
            marked++;
            if (!java.util.Objects.equals(before, libraryState(function))) changed++;
        }
        JsonObject answer = identity();
        answer.addProperty("marked", marked);
        // How many functions read otherwise in an artifact now: the host
        // exports again when any do.
        answer.addProperty("changed", changed);
        return answer;
    }

    /**
     * What a project's export says of a function and the registry, for the
     * publish to read: the entry it links to, `entry` while the function is what
     * was linked and `edited` once a write made a draft of the entry's next
     * version. No store holds this: a publish stores the link.
     */
    private String libraryState(Function function) {
        JsonObject mark = libraryMark(function);
        if (mark == null) return null;
        boolean same;
        try {
            ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(function);
            same = atItsMark(function, hash, mark);
        } catch (Exception error) {
            same = false;
        }
        JsonObject state = new JsonObject();
        state.add("id", mark.get("id"));
        state.add("version", mark.get("version"));
        state.addProperty("state", same ? "entry" : "edited");
        if (mark.has("codes")) state.add("codes", mark.get("codes"));
        return COMPACT.toJson(state);
    }

    /** The function's mark and whether it is still the entry: what a reader is told to read. */
    private void addLibraryMark(JsonObject answer, Function function) {
        if (libraryMark(function) == null) return;
        try {
            answer.add("library_entry", JsonParser.parseString(libraryState(function)));
            ghidra.feature.fid.hash.FidHashQuad hash = ExportCode.bodyHash(function);
            if (hash != null) answer.addProperty("body_key", bodyKey(hash));
            String bytes = ExportCode.referenceBytes(function);
            if (bytes != null) answer.addProperty("reference_bytes", bytes);
        } catch (Exception error) {
            // A state that is not JSON says nothing a reader can act on.
        }
    }

    /** Every function's `library_entry` written where the exporter reads it. */
    private void refreshLibraryStates() throws Exception {
        retireLibraryTags();
        StringPropertyMap states = propertyMap(ExportCode.LIBRARY_STATE);
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            String state = libraryState(function);
            String held = states.getString(function.getEntryPoint());
            if (java.util.Objects.equals(state, held)) continue;
            if (state == null) states.remove(function.getEntryPoint()); else states.add(function.getEntryPoint(), state);
        }
    }

    /**
     * The marks in one transaction, then the program saved: a publish leaves
     * no unsaved change behind it, and marking is part of the publish.
     */
    private JsonObject libraryMarkRequest(HttpExchange exchange) throws Exception {
        requireLease(exchange);
        JsonObject body = body(exchange);
        long before = program.getModificationNumber();
        int transaction = program.startTransaction("library marks");
        boolean done = false;
        JsonObject answer;
        try {
            answer = libraryMarkAll(body);
            done = true;
        } finally {
            endTransaction(transaction, done, before);
        }
        if (program.isChanged()) saveProgram("library marks");
        return answer;
    }

    /** A function this review proposes for the registry: its kind, in this project only. */
    private JsonObject libraryCandidate(Function function) {
        StringPropertyMap map = program.getUsrPropertyManager().getStringPropertyMap(LIBRARY_CANDIDATE);
        String text = map == null ? null : map.getString(function.getEntryPoint());
        return text == null ? null : JsonParser.parseString(text).getAsJsonObject();
    }

    /**
     * `POST /v1/library/candidate`: functions proposed for the registry,
     * `{"items": [{address, kind, assert_routine?}], "remove": [address]}`.
     * Nothing is decided here: the next publish offers them all, and the
     * registry takes them, or that publish is refused.
     */
    private JsonObject libraryCandidate(JsonObject body) throws Exception {
        if (body.has("items")) {
            for (JsonElement element : body.getAsJsonArray("items")) {
                JsonObject item = element.getAsJsonObject();
                String kind = required(item, "kind");
                if (!LIBRARY_KINDS.contains(kind)) {
                    throw new Failure(400, kind + " is not a library kind: edk2, amd or intel");
                }
                Function function = functionAt(required(item, "address"));
                if (libraryMark(function) != null) {
                    throw new Failure(409, function.getName() + " at " + hex(function.getEntryPoint())
                        + " links to the registry already: a change to it goes to its entry at a publish");
                }
                JsonObject candidate = new JsonObject();
                candidate.addProperty("kind", kind);
                if (item.has("assert_routine") && item.get("assert_routine").getAsBoolean()) {
                    candidate.addProperty("assert_routine", true);
                }
                propertyMap(LIBRARY_CANDIDATE).add(function.getEntryPoint(), COMPACT.toJson(candidate));
            }
        }
        if (body.has("remove")) {
            for (JsonElement element : body.getAsJsonArray("remove")) {
                propertyMap(LIBRARY_CANDIDATE).remove(functionAt(element.getAsString()).getEntryPoint());
            }
        }
        JsonArray list = new JsonArray();
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            JsonObject candidate = libraryCandidate(function);
            if (candidate == null) continue;
            candidate.addProperty("address", hex(function.getEntryPoint()));
            candidate.addProperty("name", function.getName());
            list.add(candidate);
        }
        JsonObject answer = identity();
        answer.add("candidates", list);
        return answer;
    }

    /** `POST /v1/library/decline`: the entry `id` is not offered for the function at `address` again. */
    private JsonObject libraryDecline(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        String id = required(body, "id");
        if (!id.matches("[0-9a-f-]{1,80}")) throw new Failure(400, id + " is not an entry id");
        java.util.List<String> ids = declined(function);
        if (!ids.contains(id)) ids.add(id);
        propertyMap(LIBRARY_DECLINED).add(function.getEntryPoint(), String.join(",", ids));
        JsonObject answer = identity();
        answer.addProperty("address", hex(function.getEntryPoint()));
        JsonArray list = new JsonArray();
        ids.forEach(list::add);
        answer.add("declined", list);
        return answer;
    }

    /**
     * `POST /v1/library/release`: the registry gave these bodies back, `{"items":
     * [{address, id, version, entry}]}`. Each function stops being a library
     * function: its mark comes off, so a publish does not offer it. A
     * function that holds a copy keeps it; one that only linked to the entry,
     * with no text of its own, takes the entry's review as its own first.
     */
    private JsonObject libraryRelease(JsonObject body) throws Exception {
        JsonArray list = new JsonArray();
        for (JsonElement element : body.getAsJsonArray("items")) {
            JsonObject item = element.getAsJsonObject();
            Function function = functionAt(required(item, "address"));
            JsonObject answer = new JsonObject();
            answer.addProperty("address", hex(function.getEntryPoint()));
            answer.addProperty("id", required(item, "id"));
            String plate = function.getComment();
            if (plate == null || plate.isBlank()) {
                JsonObject whole = item.deepCopy();
                whole.addProperty("mode", "whole");
                whole.addProperty("reason", "the registry gave this body back");
                applyEntry(whole);
                answer.addProperty("text", "taken from the entry");
            } else {
                answer.addProperty("text", "the module's own");
            }
            StringPropertyMap marks = program.getUsrPropertyManager().getStringPropertyMap(LIBRARY_MARK);
            if (marks != null) marks.remove(function.getEntryPoint());
            noLongerLibrary(Harvest.REASON, function.getEntryPoint());
            noLongerLibrary(Harvest.SIGNATURE_REASON, function.getEntryPoint());
            list.add(answer);
        }
        JsonObject answer = identity();
        answer.add("items", list);
        return answer;
    }

    /** A reason that cites an entry says the function is no longer that entry's; a review's own stays as it is. */
    private void noLongerLibrary(String property, Address at) throws Exception {
        StringPropertyMap reasons = program.getUsrPropertyManager().getStringPropertyMap(property);
        String reason = reasons == null ? null : reasons.getString(at);
        if (reason != null && reason.startsWith("library registry entry ")) {
            reasons.add(at, "no longer a library function: " + reason);
        }
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
     * Without the whole text where the reader does not want it: `outline=1`
     * answers the headings and the size, `section` that section's body. A
     * description runs to tens of kilobytes, and a section is what is changed.
     */
    private JsonObject description(Map<String, String> query) throws Failure {
        JsonObject answer = description();
        String section = query.get("section");
        if (section != null && !section.isEmpty()) {
            String heading = section.startsWith("## ") ? section.substring(3).trim() : section.trim();
            String body = Harvest.sectionBody(Harvest.description(program), heading);
            if (body == null) throw new Failure(404, "no section \"" + heading + "\"");
            answer.addProperty("section", heading);
            answer.addProperty("text", body);
        } else if ("1".equals(query.get("outline"))) {
            answer.remove("text");
        }
        return answer;
    }

    /**
     * The module's description, whole or one `## ` section of it: `text` is
     * the Markdown, `section` the heading whose body it replaces, `delete`
     * removes, and `before` or `after` names the section it goes beside.
     * `old_text` and `new_text` change one string inside a section, so one line
     * is changed without sending the rest; it must occur exactly once.
     */
    /** The `## ` section holding a `### ` subsection of this name when no `## ` section has it; else null. */
    private static String subsectionHolder(String description, String heading) {
        if (description == null) return null;
        String holder = null, found = null;
        for (String line : description.split("\n")) {
            if (line.startsWith("## ")) {
                holder = line.substring(3).trim();
                if (holder.equals(heading)) return null;
            } else if (line.startsWith("### ") && line.substring(4).trim().equals(heading) && found == null) {
                found = holder == null ? "(before any section)" : holder;
            }
        }
        return found;
    }

    private JsonObject setDescription(JsonObject body) throws Exception {
        if (body.has("old_text") || body.has("new_text")) replaceInSection(body);
        boolean delete = body.has("delete") && body.get("delete").getAsBoolean();
        String text = body.has("text") && !body.get("text").isJsonNull() ? body.get("text").getAsString() : null;
        boolean blank = text == null || text.isBlank();
        String before = string(body, "before", null), after = string(body, "after", null);
        boolean placed = before != null || after != null;
        if (before != null && after != null) throw new Failure(400, "give `before` or `after`, not both");
        if (placed && delete) throw new Failure(400, "`delete` takes no place");
        if (placed && (string(body, "section", null) == null || string(body, "section", null).isEmpty())) {
            throw new Failure(400, "`before` and `after` place a `section`");
        }
        // Removing is said in so many words: an empty text is as often a
        // mistake, and it would take the section with it unannounced.
        if (delete && !blank) throw new Failure(400, "`delete` removes; it takes no text");
        if (!delete && blank && !(placed && text == null)) {
            throw new Failure(400, "text is empty and nothing was changed: `delete: true` removes"
                + " a section or the whole description");
        }
        String section = string(body, "section", null);
        String next;
        if (section == null || section.isEmpty()) {
            next = delete ? null : Harvest.normalized(text);
        } else {
            String heading = section.startsWith("## ") ? section.substring(3).trim() : section.trim();
            // A section is a `## ` heading. A `###` given here would land as a
            // new `## ` section beside the one it was meant to change.
            if (heading.startsWith("#")) {
                throw new Failure(400, "section names a `## ` heading; a `###` subsection is changed through the `## ` "
                    + "section that holds it, or with `old_text` and `new_text`");
            }
            String holder = subsectionHolder(Harvest.description(program), heading);
            if (holder != null) {
                throw new Failure(409, "\"" + heading + "\" is a `###` subsection of `## " + holder + "`, not a section: "
                    + "change it through that section, or with `old_text` and `new_text`");
            }
            if (heading.isEmpty() || heading.contains("\n")) throw new Failure(400, "section is one heading's words");
            String now = Harvest.description(program);
            if (placed) {
                String anchor = (before != null ? before : after).replaceFirst("^## ", "").trim();
                if (anchor.equals(heading)) throw new Failure(400, "a section cannot go beside itself");
                if (!Harvest.sections(now).contains(anchor)) throw new Failure(404, "no section \"" + anchor + "\"");
                if (blank && !Harvest.sections(now).contains(heading)) {
                    throw new Failure(404, "no section \"" + heading + "\" to move: give its `text`");
                }
            }
            next = blank && placed ? now : Harvest.replaceSection(now, heading, delete ? "" : text);
            if (placed) next = Harvest.moveSection(next, heading, before != null ? before.replaceFirst("^## ", "").trim()
                                                                                 : after.replaceFirst("^## ", "").trim(), before == null);
            if (delete && java.util.Objects.equals(next, Harvest.normalized(now))) {
                throw new Failure(404, "no section \"" + heading + "\"");
            }
        }
        if (next != null && next.getBytes(StandardCharsets.UTF_8).length > Harvest.DESCRIPTION_LIMIT) {
            throw new Failure(413, "a description is at most " + Harvest.DESCRIPTION_LIMIT / 1024 + " KiB");
        }
        Harvest.setDescription(program, next);
        // The caller has the text it sent, and a whole description is tens of
        // kilobytes: what the write did is enough, and a read gives the rest.
        JsonObject answer = description();
        answer.remove("text");
        if (section != null && !section.isEmpty()) answer.addProperty("section", section);
        if (delete) answer.addProperty("removed", section == null || section.isEmpty() ? "description" : section);
        return answer;
    }

    /** Turns `old_text` and `new_text` into the section's new `text`. */
    private void replaceInSection(JsonObject body) throws Failure {
        String old = string(body, "old_text", null), replacement = string(body, "new_text", null);
        String section = string(body, "section", null);
        if (old == null || old.isEmpty() || replacement == null) {
            throw new Failure(400, "give `old_text` and `new_text` together; `old_text` is not empty");
        }
        if (section == null || section.isEmpty()) throw new Failure(400, "`old_text` is looked for in a `section`");
        for (String other : new String[] {"text", "delete", "before", "after"}) {
            if (body.has(other)) throw new Failure(400, "`old_text` takes no `" + other + "`");
        }
        String heading = section.startsWith("## ") ? section.substring(3).trim() : section.trim();
        String now = Harvest.sectionBody(Harvest.description(program), heading);
        if (now == null) throw new Failure(404, "no section \"" + heading + "\"");
        int first = now.indexOf(old);
        if (first < 0) throw new Failure(404, "`old_text` is not in section \"" + heading + "\"");
        if (now.indexOf(old, first + 1) >= 0) {
            throw new Failure(409, "`old_text` occurs more than once in section \"" + heading + "\": nothing was changed");
        }
        body.addProperty("text", now.substring(0, first) + replacement + now.substring(first + old.length()));
    }

    // MARK: - The lease

    private void lease(HttpExchange exchange, JsonObject body) throws Exception {
        expireLease();
        String holder = string(body, "holder", "a client");
        // The same holder asking again is a host that lost its token — a
        // server restarted while this owner ran on: it takes the lease over.
        if (leaseToken != null && leaseToken.length() > 0 && holder.equals(leaseHolder)) {
            System.out.println("OWNER LEASE TAKEN OVER by " + holder);
            if (program.isChanged()) saveProgram("lease taken over by " + holder);
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
        if (program.isChanged()) saveProgram("lease released by " + leaseHolder);
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
            if (program.isChanged()) saveProgram("lease of " + leaseHolder + " expired");
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
    /**
     * Ends a transaction begun when the program's number stood at `before`. A
     * rollback leaves the program as it was and still moves that number, so
     * what it moved is counted aside: a refused call is not a write.
     */
    private void endTransaction(int transaction, boolean commit, long before) {
        program.endTransaction(transaction, commit);
        if (commit) keepWrites();
        else rolledBack += program.getModificationNumber() - before;
    }

    /**
     * How much the program has changed over all its sessions: what a publish
     * records, and what tells a later read whether the store has it. The
     * modification number cannot say that alone, since it starts again at
     * every open, and a number from the session before compares with nothing.
     */
    private long writes() {
        return writesCarried + modification() - modificationAtOpen;
    }

    /**
     * Writes the count down as soon as it moves: an owner that dies keeps
     * nothing it did not write. A count ahead of the program after such a death
     * reads as work to publish, which a publish clears; the reverse would hide
     * work.
     */
    /** Every save goes here: what the count stood at when the program last reached the disk. */
    private void saveProgram(String why) throws Exception {
        program.save(why, TaskMonitor.DUMMY);
        keepWrites();
        keepSaved();
    }

    private void keepSaved() {
        if (savedFile == null) return;
        try {
            File next = new File(savedFile.getPath() + ".new");
            Files.writeString(next.toPath(), Long.toString(writes()));
            Files.move(next.toPath(), savedFile.toPath(), StandardCopyOption.REPLACE_EXISTING,
                       StandardCopyOption.ATOMIC_MOVE);
        } catch (Exception error) {
            System.err.println("OWNER saved: " + error);
        }
    }

    /**
     * A count ahead of the last save means an owner went away with writes it had
     * not saved: a kill, or a save that failed. They cannot be had back, and
     * the count alone reads only as work to publish, so it is said once here
     * and stays in a file beside the project. A project from before the file
     * has no last save to compare with, and says nothing.
     */
    private void noteLostWrites() {
        try {
            if (savedFile.isFile()) {
                long saved = Long.parseLong(Files.readString(savedFile.toPath()).trim());
                if (writesCarried > saved) {
                    String line = java.time.Instant.now() + ": at least " + (writesCarried - saved)
                        + " writes were not saved when the last owner ended\n";
                    System.out.print("OWNER LOST " + line);
                    Files.writeString(lostFile.toPath(), line, java.nio.file.StandardOpenOption.CREATE,
                                      java.nio.file.StandardOpenOption.APPEND);
                }
            }
        } catch (Exception error) {
            System.err.println("OWNER lost: " + error);
        }
        keepSaved();
    }

    private void keepWrites() {
        long now = writes();
        if (now == writesWritten || writesFile == null) return;
        try {
            File next = new File(writesFile.getPath() + ".new");
            Files.writeString(next.toPath(), Long.toString(now));
            Files.move(next.toPath(), writesFile.toPath(), StandardCopyOption.REPLACE_EXISTING,
                       StandardCopyOption.ATOMIC_MOVE);
            writesWritten = now;
        } catch (Exception error) {
            System.err.println("OWNER writes: " + error);
        }
    }

    private long readWrites() {
        try {
            return writesFile.isFile() ? Long.parseLong(Files.readString(writesFile.toPath()).trim()) : 0;
        } catch (Exception error) {
            System.err.println("OWNER writes: " + error);
            return 0;
        }
    }

    /**
     * What a publish records and a later read compares: the program's number
     * without the rollbacks. The decompiler's cache keeps the plain number,
     * since a rollback does restore the program it read.
     */
    private long modification() {
        return program.getModificationNumber() - rolledBack;
    }

    /** The body of a call that asks what a write would do: no lease, no transaction, `dry_run` whatever it says. */
    private JsonObject previewBody(HttpExchange exchange) throws Exception {
        JsonObject body = body(exchange);
        if (!body.has("functions")) throw new Failure(400, "a dry run takes `functions`");
        body.addProperty("dry_run", true);
        return body;
    }

    private JsonObject write(HttpExchange exchange, Change change) throws Exception {
        requireLease(exchange);
        JsonObject body = body(exchange);
        long before = program.getModificationNumber();
        int transaction = program.startTransaction(exchange.getRequestURI().getPath());
        boolean done = false;
        try {
            JsonObject answer = change.apply(body);
            noteWriteOnMarks(exchange, body, before);
            done = true;
            System.out.println("OWNER CHANGE " + leaseHolder + " " + exchange.getRequestURI().getPath()
                               + " " + body);
            return answer;
        } finally {
            endTransaction(transaction, done, before);
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
            long before = program.getModificationNumber();
            int transaction = program.startTransaction("batch item");
            boolean done = false;
            try {
                JsonObject answer = change.apply(element.getAsJsonObject()).deepCopy();
                noteWriteOnMarks(exchange, element.getAsJsonObject(), before);
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
                endTransaction(transaction, done, before);
            }
        }
        System.out.println("OWNER BATCH " + leaseHolder + " "
                           + exchange.getRequestURI().getPath() + " " + answers.size());
        JsonObject answer = identity();
        answer.add("items", answers);
        return answer;
    }

    /**
     * A write inside a marked function is the review's own from then on, also
     * when what it changed is not of the entry's description: a temporary's
     * name, a label, an equate leave the digest as it was, and the function
     * would go on reading as the entry, hiding the write. It is `dirty` until a
     * publish's registry takes what it says, and marks it afresh.
     */
    private void noteWriteOnMarks(HttpExchange exchange, JsonObject body, long before) {
        if (program.getModificationNumber() == before) return;
        if (exchange.getRequestURI().getPath().startsWith("/v1/library/")) return;
        for (String place : writePlaces(body)) {
            Address at;
            try {
                at = address(place);
            } catch (Exception error) {
                continue;
            }
            Function function = program.getFunctionManager().getFunctionContaining(at);
            JsonObject mark = function == null ? null : libraryMark(function);
            if (mark == null || isDirty(mark)) continue;
            mark.addProperty("dirty", true);
            try {
                propertyMap(LIBRARY_MARK).add(function.getEntryPoint(), COMPACT.toJson(mark));
            } catch (Exception error) {
                System.out.println("OWNER MARK not noted " + place + " " + error);
            }
        }
    }

    /** The addresses a write's body names. */
    private static java.util.List<String> writePlaces(JsonObject body) {
        java.util.List<String> places = new java.util.ArrayList<>();
        for (String key : new String[] {"function", "address"}) {
            if (body.has(key) && body.get(key).isJsonPrimitive()) places.add(body.get(key).getAsString());
        }
        for (String key : new String[] {"functions", "items"}) {
            if (!body.has(key) || !body.get(key).isJsonArray()) continue;
            for (JsonElement element : body.getAsJsonArray(key)) {
                if (element.isJsonPrimitive()) places.add(element.getAsString());
                else if (element.isJsonObject() && element.getAsJsonObject().has("address")) {
                    places.add(element.getAsJsonObject().get("address").getAsString());
                }
            }
        }
        return places;
    }

    /** Whether a marked function is still what the mark says. */
    private boolean atItsMark(Function function, ghidra.feature.fid.hash.FidHashQuad hash, JsonObject mark) throws Exception {
        return hash != null && !isDirty(mark) && reviewDigest(function, hash).equals(string(mark, "digest", ""));
    }

    /** Whether a write was made on a marked function since. A mark from before the word says `written`. */
    private static boolean isDirty(JsonObject mark) {
        return mark.has("dirty") || mark.has("written");
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
                                  + (program.getListing().getInstructionAt(at) != null
                                     ? "`ghidra_label` (/v1/rename/label)" : "`ghidra_set_data` and `name`: it is a datum"));
            }
            function = program.getFunctionManager().getFunctionContaining(at);
        }
        if (function == null) {
            throw new Failure(404, "no function at " + hex(at) + (program.getListing().getInstructionAt(at) == null
                ? ": a datum is named with `ghidra_set_data` and `name`" : ""));
        }
        String name = required(body, "name");
        // Ghidra takes `*Name` for a name; C, the panel and a reader do not.
        if (!name.matches("[A-Za-z_][A-Za-z0-9_]*")) throw new Failure(400, name + " is not a C identifier");
        // Ghidra would make a duplicate `Foo_1`; a client gets the refusal.
        for (Symbol other : program.getSymbolTable().getGlobalSymbols(name)) {
            if (!other.getAddress().equals(function.getEntryPoint())) {
                throw new Failure(409, name + " already names " + hex(other.getAddress()));
            }
        }
        // The name it already has, with no reason given, says nothing of the
        // reason it already has: a new name's silence does, since that reason
        // was for the old name.
        boolean sameName = function.getName().equals(name);
        try {
            function.setName(name, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage());
        }
        if (!sameName || body.has("reason")) why(function.getEntryPoint(), body);
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
            throw new Failure(404, "no instruction starts at " + hex(at) + ": a label marks code; a datum is named with `ghidra_set_data` and `name`");
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
     * The function's Ghidra tags, sorted.
     */
    private static void addTags(JsonObject answer, Function function) {
        JsonArray tags = new JsonArray();
        java.util.TreeSet<String> sorted = new java.util.TreeSet<>();
        for (ghidra.program.model.listing.FunctionTag held : function.getTags()) {
            if (held != null) sorted.add(held.getName());
        }
        for (String name : sorted) tags.add(name);
        answer.add("tags", tags);
    }

    /** Takes every library tag off the function: `library` and `library.<kind>`. */
    private static void removeLibraryTags(Function function) {
        java.util.List<String> held = new java.util.ArrayList<>();
        for (ghidra.program.model.listing.FunctionTag tag : function.getTags()) {
            if (tag != null && tag.getName().toLowerCase(java.util.Locale.ROOT).startsWith("library")) {
                held.add(tag.getName());
            }
        }
        for (String name : held) function.removeTag(name);
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
            // A function made inside another function's body splits it: the
            // jump the body already had into the address becomes a call of
            // nothing, and the second body is a fragment of the first. The
            // refusal names the function that holds the address; a body that
            // really is two is put together with merge, or removed with delete,
            // and then made again.
            Function holding = program.getFunctionManager().getFunctionContaining(at);
            if (holding != null) {
                throw new Failure(409, hex(at) + " is inside " + holding.getName() + " at "
                    + hex(holding.getEntryPoint())
                    + "; a function is not made inside another — merge the two with /v1/merge/functions "
                    + "or remove the split with /v1/delete/function first");
            }
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
        // Another function that ends by jumping here jumps into a function
        // now: Ghidra still reads the jump as flow inside its own body and
        // decompiles this whole body into it (issue 5872c498). It is a tail
        // call, and is marked so.
        JsonArray tailCalls = created ? markTailCalls(function) : new JsonArray();
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
        if (tailCalls.size() > 0) answer.add("tail_calls", tailCalls);
        return answer;
    }

    /**
     * The unconditional jumps between `function` and another function's entry
     * marked as calls that return (`CALL_RETURN`): tail calls. Both ways —
     * another body's jump to this entry, and this body's jump to another
     * entry — since either function can be the one made second. Answers each
     * jump, the function it is in and where it goes.
     */
    private JsonArray markTailCalls(Function function) throws Exception {
        JsonArray marked = new JsonArray();
        Address entry = function.getEntryPoint();
        for (ghidra.program.model.symbol.Reference reference : program.getReferenceManager().getReferencesTo(entry)) {
            if (!reference.getReferenceType().isJump() || reference.getReferenceType().isConditional()) continue;
            Address from = reference.getFromAddress();
            Function holding = program.getFunctionManager().getFunctionContaining(from);
            if (holding == null || holding.equals(function)) continue;
            markTailCall(from, holding, entry, marked);
        }
        for (ghidra.program.model.listing.Instruction instruction : program.getListing().getInstructions(function.getBody(), true)) {
            ghidra.program.model.symbol.FlowType flow = instruction.getFlowType();
            if (!flow.isJump() || flow.isConditional()) continue;
            for (Address target : instruction.getFlows()) {
                Function called = program.getFunctionManager().getFunctionAt(target);
                if (called == null || called.equals(function)) continue;
                markTailCall(instruction.getAddress(), function, target, marked);
            }
        }
        return marked;
    }

    private void markTailCall(Address from, Function holding, Address target, JsonArray marked) {
        ghidra.program.model.listing.Instruction jump = program.getListing().getInstructionAt(from);
        if (jump == null || jump.getFlowOverride() != ghidra.program.model.listing.FlowOverride.NONE) return;
        jump.setFlowOverride(ghidra.program.model.listing.FlowOverride.CALL_RETURN);
        decompiled.remove(holding.getEntryPoint());
        JsonObject item = new JsonObject();
        item.addProperty("address", hex(from));
        item.addProperty("function", holding.getName());
        item.addProperty("entry", hex(holding.getEntryPoint()));
        item.addProperty("to", hex(target));
        marked.add(item);
    }

    /**
     * How a jump's flow is read: `call_return` makes a jump a tail call — a
     * call of its target that returns for the function — and `none` gives the
     * instruction back its own flow. A jump into another function's entry
     * that Ghidra reads as flow inside the body decompiles that body into the
     * jumping function's C; this is the correction (issue 5872c498).
     */
    private JsonObject setFlow(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        ghidra.program.model.listing.Instruction instruction = program.getListing().getInstructionAt(at);
        if (instruction == null) throw new Failure(404, "no instruction at " + hex(at));
        String asked = required(body, "override").trim().toLowerCase(java.util.Locale.ROOT);
        ghidra.program.model.listing.FlowOverride override = switch (asked) {
            case "call_return" -> ghidra.program.model.listing.FlowOverride.CALL_RETURN;
            case "none" -> ghidra.program.model.listing.FlowOverride.NONE;
            default -> throw new Failure(400, "override is call_return or none, not " + asked);
        };
        ghidra.program.model.symbol.FlowType own = instruction.getPrototype().getFlowType(instruction.getInstructionContext());
        if (override != ghidra.program.model.listing.FlowOverride.NONE && !(own.isJump() && !own.isConditional())) {
            throw new Failure(400, hex(at) + " is " + instruction + ", not an unconditional jump");
        }
        instruction.setFlowOverride(override);
        Function holding = program.getFunctionManager().getFunctionContaining(at);
        if (holding != null) decompiled.remove(holding.getEntryPoint());
        JsonObject answer = identity();
        answer.addProperty("address", hex(at));
        answer.addProperty("instruction", instruction.toString());
        answer.addProperty("override", override == ghidra.program.model.listing.FlowOverride.NONE ? "none" : "call_return");
        if (holding != null) {
            answer.addProperty("function", holding.getName());
            answer.addProperty("entry", hex(holding.getEntryPoint()));
        }
        return answer;
    }

    /**
     * A function removed: the bytes it covered are not this module's code any
     * more. `create/function` refuses to make one inside another function's
     * body, because that split it; removing a split — or a body that was never
     * a function — is this. The instructions stay disassembled.
     */
    private JsonObject deleteFunction(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        Function function = program.getFunctionManager().getFunctionContaining(at);
        if (function == null) throw new Failure(404, "no function holds " + hex(at));
        Address entry = function.getEntryPoint();
        String name = function.getName();
        long size = function.getBody().getNumAddresses();
        program.getFunctionManager().removeFunction(entry);
        decompiled.remove(entry);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(entry));
        answer.addProperty("name", name);
        answer.addProperty("size", size);
        answer.addProperty("deleted", true);
        answer.addProperty("matched", at.equals(entry) ? "entry" : "containing");
        return answer;
    }

    /**
     * The function's local variables let go and the function decompiled
     * again: the candidate for a function the decompiler refuses — two symbols
     * assigned to one variable — where the names it kept, its own and the
     * review's, stand in the way. The review's names go with them; the answer
     * lists what was cleared, each with its storage, first use and type so that
     * it can be given back, and whether the C now decompiles at all. `names`
     * lets only those go.
     */
    private JsonObject clearLocals(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        java.util.Set<String> only = null;
        if (body.has("names")) {
            only = new java.util.LinkedHashSet<>();
            for (JsonElement name : body.getAsJsonArray("names")) only.add(name.getAsString());
            java.util.Set<String> held = new java.util.HashSet<>();
            for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) held.add(local.getName());
            for (String name : only) {
                if (!held.contains(name)) throw new Failure(404, function.getName() + " keeps no local " + name + "; nothing was changed");
            }
        }
        java.util.List<String> cleared = new java.util.ArrayList<>();
        JsonArray clearedLocals = new JsonArray();
        for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
            if (only != null && !only.contains(local.getName())) continue;
            cleared.add(local.getName());
            JsonObject item = new JsonObject();
            item.addProperty("name", local.getName());
            item.addProperty("storage", local.getVariableStorage().toString());
            item.addProperty("first_use", firstUseOf(function, local));
            item.addProperty("type", local.getDataType().getDisplayName());
            clearedLocals.add(item);
            function.removeVariable(local);
        }
        decompiled.remove(function.getEntryPoint());
        boolean decompiles = true;
        String error = null;
        try {
            DecompileResults results = decompile(function);
            decompiles = results != null && results.decompileCompleted() && results.getHighFunction() != null;
            if (!decompiles && results != null && results.getErrorMessage() != null) {
                error = results.getErrorMessage();
            }
        } catch (Exception failure) {
            decompiles = false;
            error = failure.getMessage();
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        answer.addProperty("cleared", cleared.size());
        JsonArray names = new JsonArray();
        for (String name : cleared) names.add(name);
        answer.add("names", names);
        answer.add("locals", clearedLocals);
        answer.addProperty("decompiles", decompiles);
        if (error != null) answer.addProperty("error", error);
        if (!decompiles) answer.add("suspects", decompileSuspects(function));
        return answer;
    }

    /**
     * Two functions made one: the first's body takes the second's, and the
     * second is removed. A body a conditional jump split off the function it
     * belongs to is put back this way — the way back from a split that an
     * `analyzeHeadless` run made before `create/function` refused them.
     */
    private JsonObject mergeFunctions(JsonObject body) throws Exception {
        Function into = functionAt(required(body, "into"));
        Function from = functionAt(required(body, "from"));
        if (into.getEntryPoint().equals(from.getEntryPoint())) {
            throw new Failure(400, "a function cannot be merged into itself");
        }
        if (into.getBody().contains(from.getEntryPoint())
            || into.getBody().intersects(from.getBody())) {
            throw new Failure(409, from.getName() + " at " + hex(from.getEntryPoint())
                + " is already part of " + into.getName() + " at " + hex(into.getEntryPoint()));
        }
        ghidra.program.model.address.AddressSet merged =
            new ghidra.program.model.address.AddressSet(into.getBody());
        merged.add(from.getBody());
        // `from` goes first: while it stands, its own body is an overlap. A
        // refusal after this rolls the removal back with the transaction.
        Address gone = from.getEntryPoint();
        String goneName = from.getName();
        Address kept = into.getEntryPoint();
        String keptName = into.getName();
        program.getFunctionManager().removeFunction(gone);
        // Removing a function can drop the object held for its neighbour: read
        // again, a stale one answers "Object has been deleted" to setBody.
        into = program.getFunctionManager().getFunctionAt(kept);
        if (into == null) throw new Failure(409, keptName + " at " + hex(kept) + " went with " + goneName + "; nothing was changed");
        java.util.Iterator<Function> overlapping = program.getFunctionManager().getFunctionsOverlapping(merged);
        while (overlapping.hasNext()) {
            Function other = overlapping.next();
            if (!other.getEntryPoint().equals(into.getEntryPoint())) {
                throw new Failure(409, "the bodies of " + into.getName() + " and " + goneName
                    + " cannot be merged: " + other.getName() + " at " + hex(other.getEntryPoint())
                    + " holds part of them");
            }
        }
        try {
            into.setBody(merged);
        } catch (Exception error) {
            throw new Failure(409, "the bodies cannot be merged: " + error.getMessage());
        }
        decompiled.remove(into.getEntryPoint());
        decompiled.remove(gone);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(into.getEntryPoint()));
        answer.addProperty("name", into.getName());
        answer.addProperty("size", into.getBody().getNumAddresses());
        answer.addProperty("merged", hex(gone));
        return answer;
    }

    /**
     * A body the analysis ended early, at an instruction it took for the end
     * of the flow (INT1 in a simulator backdoor), runs on to `end`: the
     * instruction is told it falls through and the bytes join the body. Only
     * decoded instructions no function holds may join.
     */
    private JsonObject extendFunction(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "function"));
        Address end = address(required(body, "end"));
        Address start = function.getBody().getMaxAddress().next();
        if (start == null || end.compareTo(start) <= 0) {
            throw new Failure(400, hex(end) + " is not past the end of " + function.getName());
        }
        AddressSet range = new AddressSet(start, end.subtract(1));
        java.util.Iterator<Function> overlapping = program.getFunctionManager().getFunctionsOverlapping(range);
        if (overlapping.hasNext()) {
            Function other = overlapping.next();
            throw new Failure(409, other.getName() + " at " + hex(other.getEntryPoint()) + " holds part of the range");
        }
        Address cursor = start;
        while (cursor.compareTo(end) < 0) {
            Instruction instruction = program.getListing().getInstructionAt(cursor);
            if (instruction == null) {
                throw new Failure(409, "no instruction starts at " + hex(cursor) + ": decode it with ghidra_redecode first");
            }
            cursor = instruction.getMaxAddress().next();
        }
        if (cursor.compareTo(end) != 0) throw new Failure(409, "an instruction runs past " + hex(end));
        Instruction last = program.getListing().getInstructionContaining(function.getBody().getMaxAddress());
        if (last == null) throw new Failure(409, function.getName() + " does not end in an instruction");
        if (last.getFallThrough() == null) last.setFallThrough(start);
        AddressSet grown = new AddressSet(function.getBody());
        grown.add(range);
        function.setBody(grown);
        decompiled.remove(function.getEntryPoint());
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("size", function.getBody().getNumAddresses());
        answer.addProperty("falls_through", hex(last.getMinAddress()));
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
        changeReason(Harvest.CODE_REASON, start, body);

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
        if (body.has("functions")) return setEquateInFunctions(body);
        if (body.has("items")) return setEquateItems(body);
        JsonObject answer = applyEquate(body);
        String name = string(body, "name", "");
        if (!name.isEmpty()) noteWhetherCPrintsIt(answer, java.util.List.of(address(required(body, "address"))), name);
        return answer;
    }

    /**
     * Several operands in one call, and one transaction: each item is what a
     * single call takes, and what the call itself gives is the default of each.
     */
    private JsonObject setEquateItems(JsonObject body) throws Exception {
        JsonArray answers = new JsonArray();
        java.util.Map<String, java.util.List<Address>> places = new java.util.LinkedHashMap<>();
        for (JsonElement element : body.getAsJsonArray("items")) {
            JsonObject one = body.deepCopy();
            one.remove("items");
            for (Map.Entry<String, JsonElement> field : element.getAsJsonObject().entrySet()) one.add(field.getKey(), field.getValue());
            JsonObject answer = applyEquate(one);
            answer.addProperty("address", required(one, "address"));
            String name = string(one, "name", "");
            if (!name.isEmpty()) places.computeIfAbsent(name, key -> new java.util.ArrayList<>()).add(address(required(one, "address")));
            answers.add(answer);
        }
        JsonObject answer = identity();
        answer.add("items", answers);
        JsonArray notInC = new JsonArray();
        for (Map.Entry<String, java.util.List<Address>> place : places.entrySet()) {
            JsonObject check = new JsonObject();
            noteWhetherCPrintsIt(check, place.getValue(), place.getKey());
            if (check.has("in_c") && !check.get("in_c").getAsBoolean()) notInC.add(place.getKey());
        }
        answer.add("not_in_c", notInC);
        return answer;
    }

    /**
     * An equate stands on the instruction; the C prints it only where the
     * decompiler keeps that constant, and may print something else: an enum
     * member the operand's type already chose. `in_c` says which of the two
     * happened, so that an answer of ok is not taken for the C reading so.
     */
    private void noteWhetherCPrintsIt(JsonObject answer, java.util.List<Address> places, String name) {
        java.util.regex.Pattern word = java.util.regex.Pattern.compile("\\b" + java.util.regex.Pattern.quote(name) + "\\b");
        java.util.Set<Function> functions = new java.util.LinkedHashSet<>();
        for (Address place : places) {
            Function function = program.getFunctionManager().getFunctionContaining(place);
            if (function != null) functions.add(function);
        }
        if (functions.isEmpty()) return;
        for (Function function : functions) {
            decompiled.remove(function.getEntryPoint());
            DecompileResults results = decompile(function);
            if (results == null || results.getDecompiledFunction() == null
                    || !word.matcher(results.getDecompiledFunction().getC()).find()) {
                answer.addProperty("in_c", false);
                return;
            }
        }
        answer.addProperty("in_c", true);
    }

    private JsonObject applyEquate(JsonObject body) throws Exception {
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
        // Unless an operand is named, only an immediate: the same number as a
        // displacement in `[reg+1]` is another thing, and is named by `operand`.
        ghidra.program.model.scalar.Scalar scalar = null;
        boolean inDisplacement = false;
        for (int index = 0; index < instruction.getNumOperands() && scalar == null; index++) {
            if (operand >= 0 && index != operand) continue;
            if (operand < 0 && !isImmediate(instruction, index)) {
                for (Object object : instruction.getOpObjects(index)) {
                    if (object instanceof ghidra.program.model.scalar.Scalar candidate && (value == null
                        || candidate.getUnsignedValue() == value || candidate.getSignedValue() == value)) {
                        inDisplacement = true;
                    }
                }
                continue;
            }
            for (Object object : instruction.getOpObjects(index)) {
                if (!(object instanceof ghidra.program.model.scalar.Scalar candidate)) continue;
                if (value == null || candidate.getUnsignedValue() == value || candidate.getSignedValue() == value) {
                    scalar = candidate;
                    operand = index;
                    break;
                }
            }
        }
        if (scalar == null && inDisplacement) {
            throw new Failure(409, "`" + instruction + "` at " + hex(at) + " holds "
                              + (value == null ? "a constant" : valueText)
                              + " only inside a memory operand, not as an immediate: give `operand` if that is meant");
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
        if (found instanceof ghidra.program.model.data.TypeDef def) found = def.getBaseDataType();
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

    /**
     * The instructions in [start, end) decoded again from `start`, in the mode
     * already there: the correction for a boundary the analysis got wrong, where
     * it decoded from a byte inside an instruction. An instruction reaching into
     * the range goes too, and what it lost is decoded again. A function whose
     * entry now falls inside an instruction was cut at a false boundary: one
     * Ghidra named is removed, and one a review named is reported, because the
     * name is the review's to move. Bodies around the range are fixed afterwards,
     * so a routine that was cut in two reads whole.
     */
    private JsonObject redecode(JsonObject body) throws Exception {
        Address start = address(required(body, "start"));
        Address end = address(required(body, "end"));
        if (end.compareTo(start) <= 0) throw new Failure(400, "end is past start: the range is [start, end)");
        Address last = end.subtract(1);
        if (!program.getMemory().contains(start, last)) {
            throw new Failure(400, hex(start) + ".." + hex(end) + " is not all in the program's memory");
        }
        ghidra.program.model.address.AddressSet range = new ghidra.program.model.address.AddressSet(start, last);
        if (program.getListing().getDefinedData(range, true).hasNext()
            || program.getListing().getDefinedDataContaining(start) != null) {
            throw new Failure(409, "defined data lies in " + hex(start) + ".." + hex(end) + ": clear it first");
        }
        Instruction before = program.getListing().getInstructionContaining(start);
        Address clearFrom = before != null ? before.getMinAddress() : start;
        Instruction after = program.getListing().getInstructionContaining(last);
        Address clearTo = after != null ? after.getMaxAddress() : last;

        java.util.Set<Address> touched = new java.util.TreeSet<>();
        Instruction previous = program.getListing().getInstructionBefore(clearFrom);
        if (previous != null) {
            Function owner = program.getFunctionManager().getFunctionContaining(previous.getMinAddress());
            if (owner != null) touched.add(owner.getEntryPoint());
        }
        ghidra.program.model.address.AddressSet cleared = new ghidra.program.model.address.AddressSet(clearFrom, clearTo);
        for (Instruction instruction : program.getListing().getInstructions(cleared, true)) {
            Function owner = program.getFunctionManager().getFunctionContaining(instruction.getMinAddress());
            if (owner != null) touched.add(owner.getEntryPoint());
        }
        program.getListing().clearCodeUnits(clearFrom, clearTo, false);
        new ghidra.app.cmd.disassemble.DisassembleCommand(new ghidra.program.model.address.AddressSet(start), range, true)
            .applyTo(program, TaskMonitor.DUMMY);
        JsonArray decoded = new JsonArray();
        for (Instruction instruction : program.getListing().getInstructions(range, true)) {
            JsonObject item = new JsonObject();
            item.addProperty("address", hex(instruction.getMinAddress()));
            item.addProperty("text", instruction.toString());
            decoded.add(item);
        }
        // Refused rather than left half done: the transaction rolls the clear back.
        if (decoded.size() == 0) throw new Failure(400, "no instruction decodes at " + hex(start));
        if (clearFrom.compareTo(start) < 0) {
            new ghidra.app.cmd.disassemble.DisassembleCommand(clearFrom, null, true).applyTo(program, TaskMonitor.DUMMY);
        }
        if (clearTo.compareTo(last) > 0 && program.getListing().getInstructionContaining(end) == null) {
            new ghidra.app.cmd.disassemble.DisassembleCommand(end, null, true).applyTo(program, TaskMonitor.DUMMY);
        }

        JsonArray removed = new JsonArray();
        JsonArray inside = new JsonArray();
        for (Address entry : new java.util.ArrayList<>(touched)) {
            if (entry.compareTo(clearFrom) < 0 || entry.compareTo(clearTo) > 0) continue;
            if (program.getListing().getInstructionAt(entry) != null
                || program.getListing().getInstructionContaining(entry) == null) continue;
            Function function = program.getFunctionManager().getFunctionAt(entry);
            if (function == null) continue;
            if (function.getSymbol().getSource() == SourceType.DEFAULT) {
                program.getFunctionManager().removeFunction(entry);
                touched.remove(entry);
                removed.add(hex(entry));
            } else {
                inside.add(hex(entry) + " " + function.getName());
            }
        }
        JsonArray functions = new JsonArray();
        for (Address entry : touched) {
            Function function = program.getFunctionManager().getFunctionAt(entry);
            if (function == null) continue;
            ghidra.app.cmd.function.CreateFunctionCmd.fixupFunctionBody(program, function, TaskMonitor.DUMMY);
            functions.add(hex(entry));
        }
        changeReason(Harvest.CODE_REASON, start, body);

        JsonObject answer = identity();
        answer.addProperty("start", hex(start));
        answer.addProperty("end", hex(end));
        answer.add("instructions", decoded);
        answer.add("functions", functions);
        if (removed.size() > 0) answer.add("functions_removed", removed);
        if (inside.size() > 0) answer.add("entries_inside_instructions", inside);
        return answer;
    }

    /** Why a change other than a name was made, kept apart from the name's reason. */
    private void changeReason(String property, Address address, JsonObject body) throws Exception {
        String reason = string(body, "reason", null);
        if (reason != null && !reason.isBlank()) propertyMap(property).add(address, reason);
    }

    /** Who made a name and why, beside the reason ApplyUefi gives its own. */
    private void why(Address address, JsonObject body) throws Exception {
        String reason = string(body, "reason", null);
        String by = string(body, "by", "agent");
        if (!by.equals("agent") && !by.equals("person")) throw new Failure(400, "by is agent or person");
        StringPropertyMap reasons = propertyMap(Harvest.REASON);
        if (!java.util.Objects.equals(reasons.getString(address), reason)) {
            if (reason != null) reasons.add(address, reason); else reasons.remove(address);
        }
        StringPropertyMap authors = propertyMap(Harvest.BY);
        if (!by.equals(authors.getString(address))) authors.add(address, by);
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
        // `shared`: the slot is named, not one symbol on it. The decompiler
        // can show several symbols on one storage — a value read as two
        // halves — and Ghidra holds one variable per storage, so the name is
        // the slot's, and every use of it reads by that name.
        boolean shared = body.has("shared") && body.get("shared").getAsBoolean();
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
        if (high == null) {
            String why = results == null ? null : results.getErrorMessage();
            throw new Failure(409, "the function does not decompile" + (why == null || why.isBlank() ? "" : ": " + why.trim())
                + "; ghidra_function_locals_reset with `names` lets the locals in the way go and keeps the rest");
        }
        if (shared) {
            if (ordinal != null) throw new Failure(400, "`shared` names a storage; a parameter is named by ordinal");
            if (storage == null) throw new Failure(400, "`shared` needs a storage");
            // A hash or `unique:` storage is the decompiler's own temporary —
            // `HASH:00000000:1` — made afresh by each decompile and shared by
            // whatever values it could not place. Naming one moves it and
            // leaves the other uses behind; it is not a slot the module holds.
            if (storage.startsWith("HASH:") || storage.startsWith("unique:")) {
                throw new Failure(409, storage + " is the decompiler's own temporary, not a slot the module holds:"
                    + " it is made afresh by each decompile and cannot be named as one — name the stack variable"
                    + " it is a split of, or say in the plate what the value is");
            }
            java.util.List<HighSymbol> group = new java.util.ArrayList<>();
            Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
            while (symbols.hasNext()) {
                HighSymbol symbol = symbols.next();
                if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
                if (!symbol.getStorage().toString().equals(storage)) continue;
                if (symbol.isParameter()) {
                    throw new Failure(409, storage + " also carries the parameter " + symbol.getName()
                        + "; name the parameter by ordinal — a register the caller passes is not the slot's");
                }
                group.add(symbol);
            }
            if (group.isEmpty()) throw new Failure(404, "no such variable in " + function.getName());
            JsonArray reported = new JsonArray();
            for (HighSymbol symbol : group) {
                JsonObject item = new JsonObject();
                Address first = symbol.getPCAddress();
                item.addProperty("first_use", first == null ? null : hex(first));
                item.addProperty("name", symbol.getName());
                reported.add(item);
            }
            String applied = name != null ? name : group.get(0).getName();
            // Ghidra holds one variable per storage, and the decompiler can show
            // several symbols on one. Named one at a time, each rename can move
            // the slot to a hash of its own, and the uses left on the old one are
            // read again and named in the next round. If a round cannot name
            // one, the call is refused and the transaction rolls back: the
            // storage is named whole, or nothing changes.
            String where = storage;
            for (int round = 0; round < 6; round++) {
                HighFunction current = decompile(function).getHighFunction();
                HighSymbol goal = null;
                if (current != null) {
                    Iterator<HighSymbol> scan = current.getLocalSymbolMap().getSymbols();
                    while (scan.hasNext()) {
                        HighSymbol symbol = scan.next();
                        if (symbol.isParameter()) continue;
                        if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
                        String at = symbol.getStorage().toString();
                        if (!at.equals(where) && !at.equals(storage)) continue;
                        if (symbol.getName().equals(applied)) continue;
                        goal = symbol;
                        break;
                    }
                }
                if (goal == null) break;
                try {
                    HighFunctionDBUtil.updateDBVariable(goal, applied, type, SourceType.USER_DEFINED);
                } catch (Exception error) {
                    throw new Failure(409, "the storage cannot be named as one: " + error.getMessage()
                        + " — nothing was changed");
                }
                decompiled.remove(function.getEntryPoint());
                HighFunction after = decompile(function).getHighFunction();
                if (after != null) {
                    Iterator<HighSymbol> now = after.getLocalSymbolMap().getSymbols();
                    while (now.hasNext()) {
                        HighSymbol symbol = now.next();
                        if (symbol.isParameter() || !symbol.getName().equals(applied)) continue;
                        where = symbol.getStorage().toString();
                        break;
                    }
                }
            }
            // Every use has to read by the name now. One left unnamed on the
            // slot means the storage was split, not named, and the call is
            // refused rather than answered as applied.
            if (type != null) requireTypeTaken(function, applied, type);
            HighFunction after = decompile(function).getHighFunction();
            java.util.List<String> left = new java.util.ArrayList<>();
            String nowStorage = storage;
            if (after != null) {
                Iterator<HighSymbol> now = after.getLocalSymbolMap().getSymbols();
                while (now.hasNext()) {
                    HighSymbol symbol = now.next();
                    if (symbol.isParameter()) continue;
                    if (symbol instanceof ghidra.program.model.pcode.EquateSymbol) continue;
                    String at = symbol.getStorage().toString();
                    if (at.equals(where)) nowStorage = at;
                    if (!at.equals(storage) && !at.equals(where)) continue;
                    if (!symbol.getName().equals(applied)) left.add(symbol.getName());
                }
            }
            if (!left.isEmpty()) {
                throw new Failure(409, "the storage " + storage + " is still read by "
                    + String.join(", ", left) + " under other names; nothing was changed");
            }
            JsonObject answer = identity();
            answer.addProperty("function", hex(function.getEntryPoint()));
            answer.addProperty("name", applied);
            answer.addProperty("storage", nowStorage);
            answer.addProperty("storage_unchanged", nowStorage.equals(storage));
            answer.add("symbols", reported);
            answer.addProperty("applied", true);
            return answer;
        }
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
            if (match != null) {
                // Two decompiler pieces can share a storage and a first use —
                // one byte read twice, say. A function holds one variable per
                // storage, so no argument here can single one of them out; the
                // refusal says that instead of asking for a first_use that was
                // given.
                throw new Failure(409, firstUse == null
                    ? "several variables are stored in " + storage + "; give first_use"
                    : "several variables in " + function.getName() + " share the storage " + storage
                        + " and the first use " + firstUse
                        + "; Ghidra holds one variable per storage, so they cannot be named apart"
                        + " — say what each is in the plate comment");
            }
            match = symbol;
        }
        if (match == null) {
            // A variable the decompiler no longer shows — left behind by a
            // retyping — still sits in the function's table and holds its
            // name. The refusal of a rename names it; the table is where the
            // rename of it lands, so the name can be freed.
            // A `first_use` has to be the variable's own: a storage alone would
            // hand a register's name to whichever local or parameter comes
            // first, and answer as if that had been asked for.
            ghidra.program.model.listing.Variable stale = null;
            if (storage != null) {
                java.util.List<ghidra.program.model.listing.Variable> onStorage = new java.util.ArrayList<>();
                for (ghidra.program.model.listing.Variable variable : function.getLocalVariables()) {
                    if (!variable.getVariableStorage().toString().equals(storage)) continue;
                    if (firstUse == null || firstUseOf(function, variable).equalsIgnoreCase(firstUse)) onStorage.add(variable);
                }
                if (onStorage.size() > 1) {
                    throw new Failure(409, "several variables are stored in " + storage + "; give first_use: "
                        + candidates(function, high, storage));
                }
                if (!onStorage.isEmpty()) stale = onStorage.get(0);
                if (stale == null && firstUse == null) {
                    for (Parameter parameter : function.getParameters()) {
                        if (parameter.getVariableStorage().toString().equals(storage)) { stale = parameter; break; }
                    }
                }
            }
            if (stale == null) {
                throw new Failure(404, firstUse == null || storage == null
                    ? "no such variable in " + function.getName()
                    : "no variable in " + function.getName() + " is stored in " + storage + " with the first use "
                        + firstUse + "; nothing was changed. A retype can merge or move locals: "
                        + candidates(function, high, storage));
            }
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
            answer.addProperty("first_use", stale instanceof Parameter ? null : firstUseOf(function, stale));
            answer.addProperty("parameter", stale instanceof Parameter);
            answer.addProperty("stale", true);
            return answer;
        }
        // A type the variable already has is no change. Given anyway, it locks
        // the type on one piece of a register the decompiler had merged: with
        // a tail call's status also in EAX, the name then lands on the status
        // (issue 537ef101). The name alone keeps the pieces together.
        // The same type means the same name too: UINT64 over Ghidra's own
        // ulonglong is a change the C prints, and was dropped under an ok
        // (issue 57972088). What is dropped is said: `type_unchanged`.
        String typeUnchanged = null;
        if (type != null && match.getDataType() != null && sameNamedType(match.getDataType(), type)) {
            typeUnchanged = match.getDataType().getDisplayName();
            type = null;
            if (name == null) {
                JsonObject answer = identity();
                answer.addProperty("function", hex(function.getEntryPoint()));
                answer.addProperty("name", match.getName());
                answer.addProperty("storage", match.getStorage().toString());
                Address first = match.getPCAddress();
                answer.addProperty("first_use", first == null ? null : hex(first));
                answer.addProperty("parameter", match.isParameter());
                answer.addProperty("unchanged", true);
                return answer;
            }
        }
        String applied = name != null ? name : match.getName();
        String asked = match.getName();
        String askedStorage = match.getStorage().toString();
        try {
            HighFunctionDBUtil.updateDBVariable(match, applied, type, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage() + holderOf(applied, function));
        }
        if (type != null) requireTypeTaken(function, applied, type);
        // The storage as it is now: a decompiler temporary becomes HASH:… once
        // it is named, and that is what names it from here on.
        decompiled.remove(function.getEntryPoint());
        JsonObject answer = identity();
        answer.addProperty("function", hex(function.getEntryPoint()));
        answer.addProperty("name", applied);
        if (typeUnchanged != null) answer.addProperty("type_unchanged", typeUnchanged);
        HighFunction after = decompile(function).getHighFunction();
        if (after != null) {
            // The decompiler can leave a name out again, as it does for an
            // `in_` value read before this function writes it: not applied.
            boolean taken = false;
            for (Iterator<HighSymbol> scan = after.getLocalSymbolMap().getSymbols(); scan.hasNext(); ) {
                if (scan.next().getName().equals(applied)) { taken = true; break; }
            }
            if (!taken) {
                throw new Failure(409, "the decompiler did not keep the name " + applied + " on " + match.getName()
                    + " (" + match.getStorage() + "); nothing was changed — say what it is in a comment");
            }
            // The name can land on another symbol: a zero hash gives Ghidra
            // nothing of its own to commit against, and the symbol stored at
            // that first use takes it. The one asked for still shows as it was.
            if (!applied.equals(asked)) {
                String holder = null;
                boolean still = false;
                for (Iterator<HighSymbol> scan = after.getLocalSymbolMap().getSymbols(); scan.hasNext(); ) {
                    HighSymbol symbol = scan.next();
                    if (symbol.getName().equals(asked) && symbol.getStorage().toString().equals(askedStorage)) still = true;
                    if (symbol.getName().equals(applied)) holder = symbol.getStorage().toString();
                }
                if (still) {
                    throw new Failure(409, "the name " + applied + " landed on another variable (" + holder + "), not on "
                        + asked + " (" + askedStorage + "); nothing was changed. This can depend on the order: name the function's other "
                        + "variables and try again, and only if it is still refused say what " + asked + " is in a comment");
                }
            }
            Iterator<HighSymbol> now = after.getLocalSymbolMap().getSymbols();
            while (now.hasNext()) {
                HighSymbol symbol = now.next();
                if (!symbol.getName().equals(applied)) continue;
                answer.addProperty("storage", symbol.getStorage().toString());
                Address first = symbol.getPCAddress();
                answer.addProperty("first_use", first == null ? null : hex(first));
                answer.addProperty("parameter", symbol.isParameter());
                // The type it holds now, so an ok can be read back in the answer itself.
                if (symbol.getDataType() != null) answer.addProperty("type", symbol.getDataType().getDisplayName());
            }
        }
        return answer;
    }

    /**
     * The decompiler can decline a type it was given: the symbol stays as it
     * was, and an unusable one is left in the program with a warning at the top
     * of the C. Answered as applied, that would be a success with no effect, so
     * the call is refused here and its transaction rolls all of it back.
     */
    private void requireTypeTaken(Function function, String name, DataType type) throws Failure {
        decompiled.remove(function.getEntryPoint());
        DecompileResults results = decompile(function);
        HighFunction high = results == null ? null : results.getHighFunction();
        DataType now = null;
        if (high != null) {
            Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
            while (symbols.hasNext()) {
                HighSymbol symbol = symbols.next();
                if (symbol.getName().equals(name)) { now = symbol.getDataType(); break; }
            }
        }
        boolean declined;
        if (now != null) {
            declined = !sameType(now, type);
        } else {
            var c = results == null ? null : results.getDecompiledFunction();
            declined = c != null && c.getC().contains("Unable to use type for symbol " + name);
        }
        // The answer below rolls back: what was just decompiled is of the
        // program as it will no longer be.
        decompiled.remove(function.getEntryPoint());
        if (declined) {
            throw new Failure(409, "the decompiler did not take the type " + type.getDisplayName() + " for " + name
                + (now == null ? "" : ": it still reads as " + now.getDisplayName())
                + " — nothing was changed; type the value it comes from, or say in a comment what it is");
        }
    }

    /** The same type by the name the C prints as well as by its layout. */
    private static boolean sameNamedType(DataType a, DataType b) {
        return a.isEquivalent(b) && a.getDisplayName().equals(b.getDisplayName());
    }

    private static boolean sameType(DataType a, DataType b) {
        return a.isEquivalent(b) || stripTypedef(a).isEquivalent(stripTypedef(b));
    }

    private static DataType stripTypedef(DataType type) {
        return type instanceof ghidra.program.model.data.TypeDef def ? def.getBaseDataType() : type;
    }

    private JsonObject setSignature(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        String nameBefore = function.getName();
        // A thunk has no prototype of its own: Ghidra keeps one, the target's,
        // so a signature given to the thunk is the target's too. The answer
        // names the target and its prototype before, so the change is not silent.
        Function target = function.isThunk() ? function.getThunkedFunction(true) : null;
        String targetBefore = target == null ? null : target.getPrototypeString(false, false);
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
        if (!command.applyTo(program)) {
            String held = nameInTheWay(function, signature);
            throw new Failure(held == null ? 400 : 409, held != null ? held : command.getStatusMsg());
        }
        // The command renames only a function Ghidra named; a signature's name
        // is the reviewer's either way.
        if (!function.getName().equals(name)) {
            try {
                function.setName(name, SourceType.USER_DEFINED);
            } catch (Exception error) {
                throw new Failure(409, error.getMessage());
            }
        }
        // Nothing on a 32-bit UEFI stack is aligned past 4 bytes, whatever the
        // convention's model says of a UINT64: left as it is, the value reads
        // one slot too high and the C prints `Address._4_4_`. Places given by
        // the caller are the caller's.
        JsonArray aligned = new JsonArray();
        if (!body.has("storage")) {
            JsonArray packed = packedStack(function, aligned);
            if (aligned.size() > 0) body.add("storage", packed);
        }
        if (body.has("storage") || body.has("return_storage")) applyStorage(function, body);
        String unsettled = settleConvention(function);
        if (body.has("unaffected")) keepRegisters(function, body.getAsJsonArray("unaffected"));
        // Why the signature is what it is has a place of its own: the name's
        // reason says where the name came from, and a signature is not that. A
        // signature that changes the name says so there, and what it replaced.
        changeReason(Harvest.SIGNATURE_REASON, function.getEntryPoint(), body);
        if (!function.getName().equals(nameBefore)) {
            JsonObject renaming = new JsonObject();
            renaming.addProperty("reason", "named in its signature (was " + nameBefore + ")");
            if (body.has("by")) renaming.add("by", body.get("by"));
            why(function.getEntryPoint(), renaming);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("signature", function.getPrototypeString(false, false));
        if (aligned.size() > 0) answer.add("aligned", aligned);
        if (unsettled != null) answer.addProperty("convention_stays_unknown", unsettled);
        answer.addProperty("calling_convention", function.getCallingConventionName());
        JsonArray kept = keptRegisters(function);
        if (kept != null) answer.add("unaffected_kept", kept);
        if (function.hasCustomVariableStorage()) {
            JsonArray storage = new JsonArray();
            for (Parameter parameter : function.getParameters()) storage.add(parameter.getVariableStorage().toString());
            answer.add("storage", storage);
            answer.addProperty("return_storage", function.getReturn().getVariableStorage().toString());
        }
        if (target != null) {
            JsonObject thunk = new JsonObject();
            thunk.addProperty("entry", hex(target.getEntryPoint()));
            thunk.addProperty("name", target.getName());
            thunk.addProperty("signature_before", targetBefore);
            thunk.addProperty("signature", target.getPrototypeString(false, false));
            answer.add("thunk_of", thunk);
            if (!target.getPrototypeString(false, false).equals(targetBefore)) {
                answer.addProperty("note", "this function is a thunk of " + target.getName() + " at "
                    + hex(target.getEntryPoint()) + ", and a thunk shares its target's prototype: the target's "
                    + "signature changed too (was `" + targetBefore + "`). Read its callers again; to keep the "
                    + "target's own signature, sign the target, not the thunk.");
            }
        }
        return answer;
    }

    /** What a convention of the program's own adds to the one it is made from. */
    private static final String KEEPS = "_keeps_";

    /**
     * Registers the function leaves as they were beyond what its convention
     * keeps — a helper that never writes EDX, which every x86 convention says
     * a call destroys. A call's effect on registers is the callee's
     * convention's, not the function's, so the program gets one of its own:
     * the function's convention plus these registers as unaffected, kept in
     * the program as a compiler-spec extension (`__stdcall_keeps_EDX`) and
     * shared by every function that keeps the same ones. An empty list goes
     * back to the convention it was made from.
     */
    private void keepRegisters(Function function, JsonArray names) throws Exception {
        ghidra.program.model.lang.CompilerSpec spec = program.getCompilerSpec();
        String current = function.getCallingConventionName();
        String root = current.contains(KEEPS) ? current.substring(0, current.indexOf(KEEPS)) : current;
        ghidra.program.model.lang.PrototypeModel rootModel = spec.getCallingConvention(root);
        if (rootModel == null) rootModel = spec.getDefaultCallingConvention();
        root = rootModel.getName();
        java.util.TreeSet<String> kept = new java.util.TreeSet<>();
        for (com.google.gson.JsonElement item : names) {
            String asked = item.getAsString().trim();
            ghidra.program.model.lang.Register register = program.getRegister(asked.toUpperCase());
            if (register == null) register = program.getRegister(asked);
            if (register == null) throw new Failure(400, "no register " + asked + " in this program's language");
            kept.add(register.getName());
        }
        if (kept.isEmpty()) {
            function.setCallingConvention(root);
            return;
        }
        String name = root + KEEPS + String.join("_", kept);
        if (spec.getCallingConvention(name) == null) {
            ghidra.program.model.pcode.XmlEncode encoder = new ghidra.program.model.pcode.XmlEncode();
            rootModel.encode(encoder, spec.getPcodeInjectLibrary());
            String xml = keeping(encoder.toString(), name, kept);
            try {
                new ghidra.program.database.SpecExtension(program).addReplaceCompilerSpecExtension(xml, TaskMonitor.DUMMY);
            } catch (Exception error) {
                throw new Failure(400, "the convention " + name + " was not taken: " + error.getMessage());
            }
            // The decompiler process took the compiler spec when it opened the
            // program: without opening it again, a call to the function reads
            // as the default convention's.
            decompiler.closeProgram();
            decompiler.setOptions(ExportCode.decompileOptions(program));
            decompiler.openProgram(program);
        }
        function.setCallingConvention(name);
    }

    /** The registers a function's own convention adds as unaffected, or null for a plain one. */
    private JsonArray keptRegisters(Function function) {
        String name = function.getCallingConventionName();
        if (name == null || !name.contains(KEEPS)) return null;
        JsonArray kept = new JsonArray();
        for (String register : name.substring(name.indexOf(KEEPS) + KEEPS.length()).split("_")) kept.add(register);
        return kept;
    }

    /**
     * The convention's XML renamed, with the registers out of `killedbycall`
     * and `likelytrash` and into `unaffected`. A result place that uses one
     * goes too — x86's `EDX:EAX` for 64 bits: the output is killed by the
     * call as a whole, so a register in any of its places is destroyed by
     * every call however `killedbycall` reads.
     */
    private String keeping(String xml, String name, java.util.Set<String> kept) throws Exception {
        javax.xml.parsers.DocumentBuilderFactory factory = javax.xml.parsers.DocumentBuilderFactory.newInstance();
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        org.w3c.dom.Document document = factory.newDocumentBuilder()
            .parse(new org.xml.sax.InputSource(new java.io.StringReader(xml)));
        org.w3c.dom.Element prototype = document.getDocumentElement();
        prototype.setAttribute("name", name);
        org.w3c.dom.Element unaffected = null;
        org.w3c.dom.Element output = null;
        java.util.List<org.w3c.dom.Element> lists = new java.util.ArrayList<>();
        for (org.w3c.dom.Node child = prototype.getFirstChild(); child != null; child = child.getNextSibling()) {
            if (!(child instanceof org.w3c.dom.Element element)) continue;
            switch (element.getTagName()) {
                case "unaffected" -> unaffected = element;
                case "output" -> output = element;
                case "killedbycall", "likelytrash" -> lists.add(element);
                default -> { }
            }
        }
        for (String registerName : kept) {
            ghidra.program.model.lang.Register register = program.getRegister(registerName);
            for (org.w3c.dom.Element list : lists) {
                java.util.List<org.w3c.dom.Node> gone = new java.util.ArrayList<>();
                for (org.w3c.dom.Node entry = list.getFirstChild(); entry != null; entry = entry.getNextSibling()) {
                    if (entry instanceof org.w3c.dom.Element element && names(element, register)) gone.add(entry);
                }
                for (org.w3c.dom.Node entry : gone) list.removeChild(entry);
            }
            if (output != null) {
                java.util.List<org.w3c.dom.Node> gone = new java.util.ArrayList<>();
                for (org.w3c.dom.Node entry = output.getFirstChild(); entry != null; entry = entry.getNextSibling()) {
                    if (!(entry instanceof org.w3c.dom.Element pentry)) continue;
                    for (org.w3c.dom.Node place = pentry.getFirstChild(); place != null; place = place.getNextSibling()) {
                        if (place instanceof org.w3c.dom.Element element && (names(element, register) || joins(element, register))) {
                            gone.add(entry);
                            break;
                        }
                    }
                }
                for (org.w3c.dom.Node entry : gone) output.removeChild(entry);
            }
            if (unaffected == null) {
                unaffected = document.createElement("unaffected");
                prototype.insertBefore(unaffected, lists.isEmpty() ? null : lists.get(0));
            }
            org.w3c.dom.Element entry = document.createElement("register");
            entry.setAttribute("name", register.getName());
            unaffected.appendChild(entry);
        }
        // A list left with no entry goes: the compiler spec's grammar takes
        // `killedbycall` and `likelytrash` only with one, and x86's
        // `likelytrash` holds nothing but ECX (issue 1413016b).
        for (org.w3c.dom.Element list : lists) {
            boolean empty = true;
            for (org.w3c.dom.Node entry = list.getFirstChild(); entry != null; entry = entry.getNextSibling()) {
                if (entry instanceof org.w3c.dom.Element) { empty = false; break; }
            }
            if (empty) prototype.removeChild(list);
        }
        javax.xml.transform.Transformer transformer = javax.xml.transform.TransformerFactory.newInstance().newTransformer();
        transformer.setOutputProperty(javax.xml.transform.OutputKeys.OMIT_XML_DECLARATION, "yes");
        java.io.StringWriter out = new java.io.StringWriter();
        transformer.transform(new javax.xml.transform.dom.DOMSource(document), new javax.xml.transform.stream.StreamResult(out));
        return out.toString();
    }

    /** Whether a `join` place has this register as a piece: `piece1="register:0x8:4"`. */
    private static boolean joins(org.w3c.dom.Element place, ghidra.program.model.lang.Register register) {
        if (!"join".equals(place.getAttribute("space"))) return false;
        org.w3c.dom.NamedNodeMap attributes = place.getAttributes();
        for (int index = 0; index < attributes.getLength(); index++) {
            org.w3c.dom.Node attribute = attributes.item(index);
            if (!attribute.getNodeName().startsWith("piece")) continue;
            String[] parts = attribute.getNodeValue().split(":");
            if (parts.length < 2) continue;
            if (parts[0].equalsIgnoreCase(register.getName())) return true;
            if (!parts[0].equals("register")) continue;
            try {
                if (Long.decode(parts[1]) == register.getOffset()) return true;
            } catch (NumberFormatException error) {
                // not an offset
            }
        }
        return false;
    }

    /** Whether a `<register>` or a register `<addr>` entry is this register. */
    private static boolean names(org.w3c.dom.Element entry, ghidra.program.model.lang.Register register) {
        if (entry.getTagName().equals("register")) return register.getName().equalsIgnoreCase(entry.getAttribute("name"));
        if (!entry.getTagName().equals("addr") && !entry.getTagName().equals("varnode")) return false;
        if (!"register".equals(entry.getAttribute("space"))) return false;
        try {
            return Long.decode(entry.getAttribute("offset")) == register.getOffset()
                && (entry.getAttribute("size").isEmpty()
                    || Integer.decode(entry.getAttribute("size")) == register.getMinimumByteSize());
        } catch (NumberFormatException error) {
            return false;
        }
    }

    /**
     * A signature someone wrote, on a function analysis left at `unknown`: the
     * decompiler would put a warning in its C for as long as it stays so. `default`
     * names no convention and prints nothing, and is taken only if it leaves every
     * place where it was. Answers why not, or null.
     */
    private String settleConvention(Function function) throws Exception {
        if (!Function.UNKNOWN_CALLING_CONVENTION_STRING.equals(function.getCallingConventionName())) return null;
        String before = placesOf(function);
        function.setCallingConvention(Function.DEFAULT_CALLING_CONVENTION_STRING);
        String after = placesOf(function);
        if (before.equals(after)) return null;
        function.setCallingConvention(Function.UNKNOWN_CALLING_CONVENTION_STRING);
        return "the default convention would move it: " + before + " to " + after;
    }

    private static String placesOf(Function function) {
        StringBuilder places = new StringBuilder(function.getReturn().getVariableStorage().toString());
        for (Parameter parameter : function.getParameters()) places.append(", ").append(parameter.getVariableStorage());
        return places.toString() + ", purge " + function.getStackPurgeSize();
    }

    /**
     * What Ghidra calls a "Parameter name conflict, likely due to concurrent
     * operation", which no concurrency caused: a local of this function
     * already holds the name a new parameter asks for.
     */
    private String nameInTheWay(Function function, FunctionDefinitionDataType signature) {
        for (ghidra.program.model.data.ParameterDefinition asked : signature.getArguments()) {
            for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
                if (local.getName().equals(asked.getName())) {
                    return "the parameter name " + asked.getName() + " is held by a local of this function ("
                        + local.getVariableStorage() + "): rename that local first, or name the parameter otherwise";
                }
            }
        }
        return null;
    }

    /**
     * Each parameter's place with the holes a 32-bit convention left closed.
     * A parameter that moves goes in `moved` with the place the convention gave
     * it, what follows a UINT64 moving with it.
     */
    private JsonArray packedStack(Function function, JsonArray moved) {
        JsonArray places = new JsonArray();
        if (program.getDefaultPointerSize() != 4) return places;
        long free = -1;
        for (Parameter parameter : function.getParameters()) {
            ghidra.program.model.listing.VariableStorage storage = parameter.getVariableStorage();
            if (!storage.isStackStorage()) {
                places.add(storage.toString());
                continue;
            }
            long at = storage.getStackOffset();
            long place = free >= 0 && at > free ? free : at;
            String written = String.format("Stack[0x%X]:%d", place, parameter.getLength());
            places.add(written);
            if (place != at) {
                JsonObject item = new JsonObject();
                item.addProperty("name", parameter.getName());
                item.addProperty("convention", storage.toString());
                item.addProperty("storage", written);
                moved.add(item);
            }
            free = (place + Math.max(parameter.getLength(), 4) + 3) & ~3L;
        }
        return places;
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
        // A convention that does not give this storage would print in the C
        // against it; the default one prints nothing. "unknown" is no way out:
        // the decompiler writes a warning into the C for it.
        String convention = conventionGives(function.getCallingConventionName(), returned, parameters)
            ? function.getCallingConventionName() : Function.DEFAULT_CALLING_CONVENTION_STRING;
        try {
            function.updateFunction(convention, returned, parameters,
                Function.FunctionUpdateType.CUSTOM_STORAGE, true, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, "the storage does not fit: " + error.getMessage());
        }
    }

    /** Whether the named convention puts this return value and these parameters where they are. */
    private boolean conventionGives(String name, ghidra.program.model.listing.ReturnParameterImpl returned,
                                    java.util.List<ghidra.program.model.listing.Variable> parameters) {
        ghidra.program.model.lang.PrototypeModel model = program.getCompilerSpec().getCallingConvention(name);
        if (model == null) return false;
        ghidra.program.model.data.DataType[] types = new ghidra.program.model.data.DataType[parameters.size() + 1];
        types[0] = returned.getDataType();
        for (int index = 0; index < parameters.size(); index++) types[index + 1] = parameters.get(index).getDataType();
        ghidra.program.model.listing.VariableStorage[] places = model.getStorageLocations(program, types, false);
        if (places.length != types.length || !places[0].toString().equals(returned.getVariableStorage().toString())) return false;
        for (int index = 0; index < parameters.size(); index++) {
            if (!places[index + 1].toString().equals(parameters.get(index).getVariableStorage().toString())) return false;
        }
        return true;
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

    /**
     * Makes room for a datum where the analysis decoded instructions: refused
     * unless asked, with what stands there; asked, the instructions go and
     * the functions holding them give those bytes up. A function's entry in
     * the range is never cleared: that is `ghidra_function_delete`'s.
     */
    private JsonObject clearCodeForDatum(Address address, DataType type, boolean clear) throws Exception {
        if (type.getLength() <= 0) return null;
        Address last = address.add(type.getLength() - 1);
        Instruction before = program.getListing().getInstructionContaining(address);
        Address from = before != null ? before.getMinAddress() : address;
        java.util.List<Instruction> found = new java.util.ArrayList<>();
        for (Instruction instruction : program.getListing().getInstructions(new AddressSet(from, last), true)) {
            found.add(instruction);
        }
        if (found.isEmpty()) return null;
        Address to = found.get(found.size() - 1).getMaxAddress();
        if (to.compareTo(last) < 0) to = last;
        AddressSet range = new AddressSet(from, to);
        java.util.Set<Function> owners = new java.util.LinkedHashSet<>();
        for (Instruction instruction : found) {
            Function owner = program.getFunctionManager().getFunctionContaining(instruction.getMinAddress());
            if (owner != null) owners.add(owner);
        }
        for (Function owner : owners) {
            if (range.contains(owner.getEntryPoint())) {
                throw new Failure(409, hex(address) + " holds the entry of " + owner.getName()
                    + ": a function has to be deleted before its entry can be data");
            }
        }
        if (!clear) {
            Function owner = owners.isEmpty() ? null : owners.iterator().next();
            throw new Failure(409, "the type covers " + found.size() + " instruction(s) from " + hex(found.get(0).getMinAddress())
                + (owner == null ? "" : ", in the body of " + owner.getName())
                + ": `clear_code: true` removes them and shortens the body");
        }
        JsonArray shortened = new JsonArray();
        for (Function owner : owners) {
            owner.setBody(owner.getBody().subtract(range));
            shortened.add(owner.getName());
        }
        program.getListing().clearCodeUnits(from, to, false);
        JsonObject cleared = new JsonObject();
        cleared.addProperty("instructions", found.size());
        cleared.add("functions_shortened", shortened);
        return cleared;
    }

    private JsonObject setData(JsonObject body) throws Exception {
        JsonObject answerCleared = null;
        Address address = address(required(body, "address"));
        if (body.has("type") && !body.get("type").isJsonNull()) {
            // A datum needs bytes: outside the image there are none, so an
            // MMIO register takes a name only (issue 71557325), and its type
            // is said in a comment where the code reads it.
            if (!program.getMemory().contains(address)) {
                throw new Failure(400, hex(address) + " is outside the image: it takes a name without `type`; "
                    + "say the register's width and meaning in an end-of-line comment where the code reads it");
            }
            DataType type = type(body.get("type").getAsString());
            answerCleared = clearCodeForDatum(address, type, body.has("clear_code") && body.get("clear_code").getAsBoolean());
            DataUtilities.createData(program, address, type, -1,
                                     DataUtilities.ClearDataMode.CLEAR_ALL_CONFLICT_DATA);
            if (program.getListing().getDefinedDataAt(address) == null) {
                throw new Failure(409, "no datum was made at " + hex(address));
            }
        }
        String name = string(body, "name", null);
        if (name != null && name.isEmpty()) {
            // An empty name takes a leftover label off the address, as it does
            // on a jump target. Only a label: a function's symbol is the function.
            Symbol primary = program.getSymbolTable().getPrimarySymbol(address);
            if (primary == null || primary.isDynamic()) {
                throw new Failure(404, "no label a review can remove at " + hex(address));
            }
            if (primary.getSymbolType() != ghidra.program.model.symbol.SymbolType.LABEL) {
                throw new Failure(409, hex(address) + " is named by a " + primary.getSymbolType() + ", not a label");
            }
            primary.delete();
        } else if (name != null) {
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
        // A name outside the image is how a review names an MMIO register, and
        // the C prints it where the code uses that address; nothing else lists it.
        if (!program.getMemory().contains(address)) answer.addProperty("outside_memory", true);
        Data datum = program.getListing().getDefinedDataAt(address);
        if (datum != null) answer.addProperty("type", datum.getDataType().getDisplayName());
        Symbol named = program.getSymbolTable().getPrimarySymbol(address);
        answer.addProperty("name", named == null ? null : named.getName());
        if (answerCleared != null) answer.add("code_cleared", answerCleared);
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
            if (body.has("shared") && body.get("shared").getAsBoolean()) return withdrawShared(body);
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
            resolved = functionTypedef(parsed);
            if (resolved == null) {
                resolved = program.getDataTypeManager().resolve(parsed, DataTypeConflictHandler.REPLACE_HANDLER);
            }
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
        nameFunctionPointerMembers(resolved);
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
     * `typedef RET NAME(…)` is the function definition NAME: the parser makes a
     * typedef of that name over a function of the same name, and resolved as
     * it is, that typedef lands at the root beside the definition the program
     * already holds — a field's pointer named into `/functions` — and shadows
     * it. The definition the program holds takes the new signature instead,
     * and every self-naming typedef over it, the parser's or an earlier
     * call's, is replaced by it wherever it is used. Null for any other C.
     */
    private DataType functionTypedef(DataType parsed) throws Exception {
        if (!(parsed instanceof ghidra.program.model.data.TypeDef def)
            || !(def.getBaseDataType() instanceof ghidra.program.model.data.FunctionDefinition function)
            || !def.getName().equals(function.getName())) return null;
        ghidra.program.model.data.DataTypeManager manager = program.getDataTypeManager();
        java.util.List<DataType> named = new java.util.ArrayList<>();
        manager.findDataTypes(def.getName(), named);
        ghidra.program.model.data.FunctionDefinition target = null;
        for (DataType type : named) {
            if (type.getDataTypeManager() != manager
                || !(type instanceof ghidra.program.model.data.FunctionDefinition held)) continue;
            // The one a field was named into before the parser's copy.
            if (target == null || held.getCategoryPath().getPath().equals("/functions")) target = held;
        }
        if (target == null) {
            target = (ghidra.program.model.data.FunctionDefinition) manager.resolve(function,
                DataTypeConflictHandler.REPLACE_HANDLER);
        } else if (!target.isEquivalent(function)) {
            target.replaceWith(function);
        }
        for (DataType type : named) {
            if (type == target || type.getDataTypeManager() != manager) continue;
            boolean selfNaming = type instanceof ghidra.program.model.data.TypeDef shadow
                && shadow.getBaseDataType() instanceof ghidra.program.model.data.FunctionDefinition;
            if (selfNaming || type instanceof ghidra.program.model.data.FunctionDefinition) {
                manager.replaceDataType(type, target, false);
            }
        }
        return target;
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
            return sameShape(mine, theirs, new java.util.HashSet<>());
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
    private static String firstUseOf(Function function, ghidra.program.model.listing.Variable variable) {
        return hex(function.getEntryPoint().addWrap(variable.getFirstUseOffset()));
    }

    /** What a storage holds now, for a refusal: the decompiler's symbols and the table's variables. */
    private String candidates(Function function, HighFunction high, String storage) {
        java.util.Set<String> found = new java.util.LinkedHashSet<>();
        Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
        while (symbols.hasNext()) {
            HighSymbol symbol = symbols.next();
            if (!symbol.getStorage().toString().equals(storage)) continue;
            Address first = symbol.getPCAddress();
            found.add(symbol.getName() + (symbol.isParameter() ? " (parameter " + symbol.getCategoryIndex() + ")"
                : " (first_use " + (first == null ? "none" : hex(first)) + ")"));
        }
        for (ghidra.program.model.listing.Variable variable : function.getLocalVariables()) {
            if (!variable.getVariableStorage().toString().equals(storage)) continue;
            found.add(variable.getName() + " (first_use " + firstUseOf(function, variable) + ")");
        }
        return found.isEmpty() ? "that storage holds nothing now" : "that storage holds " + String.join(", ", found);
    }

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
                holders.append(" (storage ").append(variable.getVariableStorage());
                if (!(variable instanceof Parameter)) holders.append(", first_use ").append(firstUseOf(function, variable));
                holders.append(")");
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
                    JsonObject withdrawn = readWithdrawn();
                    String taken = withdrawn.has(name) ? name : withdrawn.has(alternate) ? alternate : null;
                    if (taken != null) answer.add("withdrawn", withdrawn.get(taken));
                }
                FileDataTypeManager shared = FileDataTypeManager.openFileArchive(copy, false);
                try {
                    inShared = findAny(shared, name, alternate);
                    answer.add("shared", TypeText.describe(inShared));
                    if (here != null && inShared != null) {
                        // `isEquivalent` reads past `.conflict`, so a member's
                        // type name is compared as well.
                        // The same as the publish's merge reads it — a typedef
                        // that only renames its function is that function —
                        // and with the same texts.
                        answer.addProperty("same", (inShared.isEquivalent(here)
                                || (sameShape(here, inShared, new java.util.HashSet<>()) && sameTexts(here, inShared)))
                            && !memberTypesRenamed(here, inShared));
                    }
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
        if (text.startsWith("/")) return typeAtPath(text);
        importTypes(text);
        try {
            DataType type = new DataTypeParser(program.getDataTypeManager(), program.getDataTypeManager(),
                                               null, DataTypeParser.AllowedDataTypes.ALL).parse(text);
            if (type == null) throw new Failure(400, "no type " + text);
            return type;
        } catch (Failure failure) {
            throw failure;
        } catch (Exception error) {
            throw new Failure(400, "no type " + text + ": " + ambiguity(text, error.getMessage()));
        }
    }

    /**
     * A type by its full path, with any `*` after it. EDK2's function pointers
     * are held twice under one name, the typedef and its function type, and
     * only the path says which is meant. The parser does not read paths.
     */
    private DataType typeAtPath(String text) throws Failure {
        java.util.regex.Matcher parts = java.util.regex.Pattern.compile("^(/[^*]*?)\\s*((?:\\*\\s*)*)$").matcher(text);
        if (!parts.matches()) throw new Failure(400, "no type " + text);
        ghidra.program.model.data.DataTypeManager manager = program.getDataTypeManager();
        DataType type = manager.getDataType(parts.group(1));
        for (FileDataTypeManager source : new FileDataTypeManager[] {reviewArchive, archive}) {
            if (type != null || source == null) continue;
            DataType there = source.getDataType(parts.group(1));
            if (there != null) type = manager.resolve(there, DataTypeConflictHandler.DEFAULT_HANDLER);
        }
        if (type == null) throw new Failure(400, "no type " + text);
        for (char mark : parts.group(2).toCharArray()) {
            if (mark == '*') type = new ghidra.program.model.data.PointerDataType(type, manager);
        }
        return type;
    }

    /**
     * Ghidra's parser answers "unrecognized" for a name it holds twice with
     * different definitions, since it has nobody to ask which. Said as it is,
     * with the holders, because the name plainly does exist.
     */
    private String ambiguity(String text, String message) {
        java.util.regex.Matcher words = java.util.regex.Pattern.compile("[A-Za-z_][A-Za-z0-9_]*").matcher(text);
        while (words.find()) {
            java.util.List<DataType> held = new java.util.ArrayList<>();
            program.getDataTypeManager().findDataTypes(words.group(), held);
            if (held.size() < 2) continue;
            java.util.List<String> paths = new java.util.ArrayList<>();
            for (DataType type : held) paths.add(type.getPathName());
            return "the program holds " + words.group() + " " + held.size() + " times, differently: "
                + String.join(", ", paths) + " — name the one meant by its path, or delete a copy that is wrong";
        }
        return message;
    }

    // MARK: - Program

    /**
     * An offset from a function's entry as an entry holds it: `%X` of a long, so
     * code before the entry, a loop head the body jumps back to, reads as
     * 0xFFFFFFFFFFFFFFFA, which `Long.decode` refuses.
     */
    private static long relative(String text) {
        return text.startsWith("0x") || text.startsWith("0X")
            ? Long.parseUnsignedLong(text.substring(2), 16) : Long.decode(text);
    }

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
