import Testing
@testable import CockerDaemon

// Cas limites cherchés en essayant de casser le parseur, à partir de
// Dockerfile réels (uv, cargo, apt, pnpm). Le but n'est pas de dupliquer
// la suite existante mais de trouver ce qui passerait à travers.
@Suite("BuildKit mount flags — cas limites")
struct RunMountFlagsEdgeTests {

    // La doc uv officielle met deux montages ET un =target avec des
    // virgules dans une valeur entre guillemets.
    @Test("le motif exact de la doc uv est géré")
    func realWorldUvLine() {
        let p = RunMountFlags.parse(
            "--mount=type=cache,target=/root/.cache/uv "
            + "--mount=type=bind,source=uv.lock,target=uv.lock "
            + "uv sync --locked")
        // bind doit faire échouer : il change ce que la commande voit.
        #expect(p.unsupportedTypes.contains("bind"))
    }

    // Un heredoc ou une commande contenant « --mount » plus loin ne doit
    // pas être amputé.
    @Test("un --mount au milieu de la commande est préservé")
    func mountInsideCommandIsKept() {
        let p = RunMountFlags.parse("echo docker run --mount=type=bind,src=/a")
        #expect(p.command == "echo docker run --mount=type=bind,src=/a")
        #expect(p.unsupportedTypes.isEmpty)
        #expect(p.ignoredTypes.isEmpty)
    }

    // Forme JSON exec : RUN ["/bin/sh", "-c", "..."]. Pas de flag possible.
    @Test("la forme exec JSON traverse intacte")
    func execFormIsUntouched() {
        let raw = "[\"/bin/sh\", \"-c\", \"echo ok\"]"
        let p = RunMountFlags.parse(raw)
        #expect(p.command == raw)
    }

    // type= écrit en majuscules, vu dans des Dockerfile générés.
    @Test("le type est reconnu quelle que soit la casse")
    func typeIsCaseInsensitive() {
        let p = RunMountFlags.parse("--mount=TYPE=CACHE,target=/x uv sync")
        #expect(p.command == "uv sync")
        #expect(p.ignoredTypes == ["cache"])
    }

    // Indentation par tabulation après le flag.
    @Test("une tabulation sépare aussi le flag de la commande")
    func tabSeparatorWorks() {
        let p = RunMountFlags.parse("--mount=type=cache,target=/x\tmake build")
        #expect(p.command == "make build")
    }

    // Espaces multiples, courant après un « \ » de continuation.
    @Test("les espaces multiples ne laissent pas de reste")
    func repeatedSpacesAreTrimmed() {
        let p = RunMountFlags.parse("--mount=type=cache,target=/x    npm ci")
        #expect(p.command == "npm ci")
    }

    // Un RUN vide ne doit pas planter.
    @Test("une entrée vide ne provoque pas de plantage")
    func emptyInputIsSafe() {
        let p = RunMountFlags.parse("")
        #expect(p.command == "")
        #expect(p.ignoredTypes.isEmpty)
    }

    // Un --mount sans rien derrière : dégénéré mais ne doit pas boucler.
    @Test("un flag sans commande ne boucle pas indéfiniment")
    func flagWithoutCommandTerminates() {
        let p = RunMountFlags.parse("--mount=type=cache,target=/x")
        #expect(p.command == "")
        #expect(p.ignoredTypes == ["cache"])
    }

    // --network est l'autre flag BuildKit fréquent (RUN --network=none).
    // On veut savoir s'il est traité ou s'il partirait au shell.
    @Test("le flag --network est signalé plutôt que passé au shell")
    func networkFlagIsNotLeakedToShell() {
        let p = RunMountFlags.parse("--network=none pip install .")
        // Documente le comportement : si la commande commence encore par
        // « --network », le shell recevra le flag comme en 0.7.13.17.
        #expect(!p.command.hasPrefix("--network"),
                "--network partirait au shell, même classe de bug que --mount")
    }
}
