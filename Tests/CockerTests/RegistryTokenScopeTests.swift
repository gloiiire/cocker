import Testing
@testable import CockerCore

// Panne rencontrée en conditions réelles : le premier `cocker pull` d'une
// session réussissait, tous les suivants échouaient avec
// « Manifest not found », alors que les images existaient (vérifié : le
// registre répondait HTTP 200 à une requête directe).
//
// Deux défauts distincts se cumulaient, d'où deux séries de tests.
@Suite("Registre : portée du jeton et diagnostic")
struct RegistryTokenScopeTests {

    // MARK: - 1. Le jeton mis en cache doit être propre au dépôt

    // Docker Hub délivre un jeton valable pour UN dépôt. Réutiliser celui
    // d'alpine pour busybox donne 401. Mesuré :
    //   alpine  avec son jeton  -> 200
    //   busybox avec le jeton d'alpine -> 401
    //   busybox avec son jeton  -> 200
    @Test("deux dépôts du même registre ne partagent pas un jeton")
    func distinctRepositoriesGetDistinctKeys() {
        let alpine = RegistryClient.tokenCacheKey(
            registry: "registry-1.docker.io", repository: "library/alpine", scope: "pull")
        let busybox = RegistryClient.tokenCacheKey(
            registry: "registry-1.docker.io", repository: "library/busybox", scope: "pull")
        #expect(alpine != busybox,
                "le jeton d'alpine serait réutilisé pour busybox, d'où un 401")
    }

    // La raison d'être initiale de la clé : ne pas mélanger push et pull.
    @Test("les portées push et pull restent séparées")
    func scopesStaySeparate() {
        let lecture = RegistryClient.tokenCacheKey(
            registry: "r", repository: "d", scope: "pull")
        let ecriture = RegistryClient.tokenCacheKey(
            registry: "r", repository: "d", scope: "push")
        #expect(lecture != ecriture)
    }

    // Deux registres différents ne doivent évidemment pas se confondre.
    @Test("deux registres distincts ont des clés distinctes")
    func distinctRegistriesGetDistinctKeys() {
        let hub = RegistryClient.tokenCacheKey(
            registry: "registry-1.docker.io", repository: "n/a", scope: "pull")
        let ghcr = RegistryClient.tokenCacheKey(
            registry: "ghcr.io", repository: "n/a", scope: "pull")
        #expect(hub != ghcr)
    }

    // Le cache doit quand même faire son travail : même triplet, même clé.
    @Test("un même triplet réutilise bien le jeton en cache")
    func identicalTripleHitsTheCache() {
        #expect(RegistryClient.tokenCacheKey(registry: "r", repository: "d", scope: "pull")
                == RegistryClient.tokenCacheKey(registry: "r", repository: "d", scope: "pull"))
    }

    // Le séparateur ne doit pas permettre à deux triplets différents de
    // produire la même clé par recollement.
    @Test("le découpage des champs n'est pas ambigu")
    func fieldsCannotBeConfused() {
        let a = RegistryClient.tokenCacheKey(
            registry: "r|x", repository: "d", scope: "pull")
        let b = RegistryClient.tokenCacheKey(
            registry: "r", repository: "x|d", scope: "pull")
        #expect(a != b, "deux contextes différents produiraient la même clé")
    }

    // MARK: - 2. Le message doit nommer la vraie cause

    // C'est ce qui a coûté le plus de temps : l'image existait, mais le
    // message affirmait le contraire.
    @Test("un refus d'autorisation ne se présente pas comme image absente")
    func unauthorizedIsNotReportedAsMissing() {
        for statut in [401, 403] {
            let msg = RegistryClient.pullFailureExplanation(status: statut).lowercased()
            #expect(!msg.contains("not found"),
                    "HTTP \(statut) présenté comme une image inexistante")
            #expect(msg.contains("author"), "la cause réelle n'est pas nommée")
        }
    }

    // Cas très courant sur Docker Hub sans compte.
    @Test("la limitation de débit est nommée et la sortie est indiquée")
    func rateLimitIsNamedWithAWayOut() {
        let msg = RegistryClient.pullFailureExplanation(status: 429).lowercased()
        #expect(msg.contains("rate limit"))
        #expect(msg.contains("login"), "aucune marche à suivre proposée")
    }

    // Une panne côté registre ne doit pas laisser croire à une erreur de
    // frappe dans le nom de l'image.
    @Test("une erreur serveur est attribuée au registre")
    func serverErrorIsAttributedToTheRegistry() {
        for statut in [500, 502, 503] {
            let msg = RegistryClient.pullFailureExplanation(status: statut).lowercased()
            #expect(msg.contains("registry"))
            #expect(!msg.contains("not found"))
        }
    }

    // Un code inattendu doit rester lisible plutôt que muet.
    @Test("un code inattendu est affiché tel quel")
    func unexpectedStatusIsStillReadable() {
        #expect(RegistryClient.pullFailureExplanation(status: 418).contains("418"))
    }

    // Chaque message doit être exploitable : nommer le code observé.
    @Test("chaque message cite le code HTTP reçu")
    func everyMessageQuotesItsStatus() {
        for statut in [401, 403, 429, 500, 418] {
            #expect(RegistryClient.pullFailureExplanation(status: statut)
                .contains("\(statut)"), "HTTP \(statut) absent du message")
        }
    }
}
