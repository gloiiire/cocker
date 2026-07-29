import Testing
@testable import CockerDaemon

// Deuxième passe, ciblée sur la gestion de --network / --security ajoutée
// après la première série. Même méthode : chercher ce qui passe à travers.
@Suite("BuildKit RUN flags — seconde passe")
struct RunMountFlagsSecondPassTests {

    // Le cas --mount est protégé contre « --mountains » ; --network et
    // --security méritent la même garde, sinon une commande commençant par
    // un flag homonyme serait amputée.
    @Test("un flag seulement homonyme de --network n'est pas consommé")
    func networkLookalikeIsNotConsumed() {
        let cmd = "--network-manager-cli restart"
        let p = RunMountFlags.parse(cmd)
        #expect(p.command == cmd)
        #expect(p.ignoredTypes.isEmpty)
        #expect(p.unsupportedTypes.isEmpty)
    }

    @Test("un flag seulement homonyme de --security n'est pas consommé")
    func securityLookalikeIsNotConsumed() {
        let cmd = "--security-opt seccomp=unconfined ./run"
        let p = RunMountFlags.parse(cmd)
        #expect(p.command == cmd)
        #expect(p.unsupportedTypes.isEmpty)
    }

    // Quand seul --network=default est ignoré, parler de « mount » et de
    // « cache/tmpfs » désigne quelque chose qui n'est pas dans la ligne.
    @Test("l'avertissement ne parle pas de montage quand il s'agit du réseau")
    func warningDoesNotMentionMountForNetwork() {
        let msg = RunMountFlags.warning(for: ["network"]).lowercased()
        #expect(msg.contains("network"))
        #expect(!msg.contains("mount"),
                "message trompeur : aucun montage n'est en cause ici")
    }

    // Ordre inverse de la doc BuildKit : les flags peuvent se suivre
    // dans n'importe quel ordre.
    @Test("--network placé après --mount est également traité")
    func flagsAreHandledInAnyOrder() {
        let p = RunMountFlags.parse(
            "--mount=type=cache,target=/x --network=none pip install .")
        #expect(p.command == "pip install .")
        #expect(p.unsupportedTypes.contains("network=none"))
    }

    // Le message d'échec doit nommer le bon coupable quand les deux
    // familles sont présentes.
    @Test("un échec mixte nomme le montage et le flag séparément")
    func mixedFailureNamesBoth() {
        let msg = RunMountFlags.failure(for: ["bind", "network=none"])
        #expect(msg.contains("bind"))
        #expect(msg.contains("network=none"))
    }
}
