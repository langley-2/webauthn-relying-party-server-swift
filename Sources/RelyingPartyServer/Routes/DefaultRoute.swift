//
// Copyright contributors to the IBM Security Verify WebAuthn Relying Party Server for Swift
//

import Vapor

///  A platform supported by the relying party service.
enum Platform: String, Equatable {
    /// IBM Security Verify
    case isv
    
    /// IBM Security Verify Access
    case isva
}

/// The default route controller that processes requests to manage user sign-up, registration and sign-in processes.
struct DefaultRoute: RouteCollection {
    private let webAuthnService: WebAuthnService
    private let userService: UserService
    private let authTokenService: TokenService
    private let apiTokenService: TokenService
    private let webApp: Application
    
    /// Initializes the default routes for user interactions.
    /// - Parameters:
    ///   - webApp: Core type representing a Vapor application.
    init(_ webApp: Application) throws {
        // Load the base URL for interacting with the services.
        guard let platformValue = Environment.get("PLATFORM"), let platform = Platform(rawValue: platformValue.lowercased()) else {
            fatalError("The platform environment variable not set or invalid. Valid PLATFORM values are 'ISV' or 'ISVA'.")
        }
        
        // Load the base URL for interacting with the services.
        guard let base = Environment.get("BASE_URL"), let baseURL = URL(string: base) else {
            fatalError("The base URL environment variables not set or invalid.")
        }
        
        guard let relyingPartyId = Environment.get("FIDO2_RELYING_PARTY_ID") else {
            fatalError("The relying party identifier is not set or invalid.")
        }
        
        guard let apiClientId = Environment.get("API_CLIENT_ID"), let apiClientSecret = Environment.get("API_CLIENT_SECRET") else {
            fatalError("FIDO2 related environment variables not set or invalid.")
        }
        
       // If not provided, then the /authenticate, /signup and /validate endpoints will return a 400 Bad Request response.
        guard let authClientId = Environment.get("AUTH_CLIENT_ID"), let authClientSecret = Environment.get("AUTH_CLIENT_SECRET") else {
            fatalError("User authenticaton related environment variables not set or invalid.")
        }
        
        // Configure the proxy if settings provided.
        if let proxy = Environment.get("PROXY_HOST"), let proxyHost = URL(string: proxy), let port = Environment.get("PROXY_PORT"), let proxyPort = Int(port) {
            webApp.logger.info("Server proxy configured on \(proxyHost.absoluteString):\(proxyPort)")
            webApp.http.client.configuration.proxy = .server(host: proxyHost.absoluteString, port: proxyPort)
        }
        
        self.webApp = webApp
        
       // Create instances of services for Token (authorization of users and api clients), users and FIDO WebAuthn.
        switch platform {
        case .isv:
            self.userService = ISVUserService(webApp, baseURL: baseURL)
            self.webAuthnService = ISVWebAuthnService(webApp, baseURL: baseURL, relyingPartyId: relyingPartyId)
            self.authTokenService = ISVTokenService(webApp, baseURL: baseURL, clientId: authClientId, clientSecret: authClientSecret)
            self.apiTokenService = ISVTokenService(webApp, baseURL: baseURL, clientId: apiClientId, clientSecret: apiClientSecret)
        case .isva:
            self.userService = ISVAUserService(webApp, baseURL: baseURL)
            self.webAuthnService = ISVAWebAuthnService(webApp, baseURL: baseURL, relyingPartyId: relyingPartyId)
            self.authTokenService = ISVATokenService(webApp, baseURL: baseURL, clientId: authClientId, clientSecret: authClientSecret)
            self.apiTokenService = ISVATokenService(webApp, baseURL: baseURL, clientId: apiClientId, clientSecret: apiClientSecret)
        }
        
        self.webApp.logger.info("Configured for \(platform.rawValue)")
    }
    
    func boot(routes: RoutesBuilder) throws {
        // Returns a simply string to indicate the relying party is running.
        webApp.routes.get { _ in
            return "Welcome to IBM Security Verify Relying Party Server for Swift"
        }
        
        let route = routes.grouped("v1")
        // Used for existing accounts with a password resulting in an ROPC to token endpoint.
        route.post("authenticate", use: authenticate)
        
        // Used to initiate a user sign-up, which also requires the OTP validation.
        route.post("signup", use: signup)
        route.post("validate", use: validate)
        
        // Used to generate a FIDO challenge for attestation and assertion.
        route.post("challenge", use: challenge)
        
        // Used to register an authenticatpr with a FIDO attestation result.
        route.post("register", use: register)
        
        // Used to validate an authenticator with a FIDO assertion result.
        route.post("signin", use: signin)
    }
    
    // MARK: User Authentication, Sign-up and Validation
    
    /// The user authentication request.
    /// - Parameters:
    ///   - req: Represents an HTTP request.
    /// - Returns: A ``Token`` representing the authenticated user.
    ///
    /// An example JSON request body for authenticating a user:
    /// ```
    /// {
    ///    "email": "john@citizen.com",
    ///    "password": "a1b2c3d4"
    /// }
    /// ```
    func authenticate(_ req: Request) async throws -> Token {
        // Validate the request data.
        try UserAuthentication.validate(content: req)
        let authenticate = try req.content.decode(UserAuthentication.self)
        
        do {
            return try await authTokenService.password(username: authenticate.username, password: authenticate.password)
        }
        catch let error {
            req.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            throw error
        }
    }
    
    /// The user sign-up request.
    /// - Parameters:
    ///   - req: Represents an HTTP request.
    /// - Returns: A ``OTPChallenge`` structure representing the new user sign-up.
    ///
    /// An example JSON request body for initiating a user sign-up:
    /// ```
    /// {
    ///    "name": "John Citizen",
    ///    "email": "john@citizen.com"
    /// }
    /// ```
    func signup(_ req: Request) async throws -> OTPChallenge {
        // Validate the request data.
        try UserSignUp.validate(content: req)
        let user = try req.content.decode(UserSignUp.self)
        
        do {
            let result = try await userService.generateOTP(token: try await token, email: user.email)
            
            // Calculate the cache expiry in seconds for the OTP transaction.
            let seconds = Int(result.expiry.timeIntervalSinceNow)
            req.logger.info("Caching OTP \(result.transactionId). Set to expire in \(seconds) seconds.")
        
            try await req.cache.set(result.transactionId, to: user, expiresIn: CacheExpirationTime.seconds(seconds))
            
            return result
        }
        catch let error {
            req.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            throw error
        }
    }
    
    /// Validate the user sign-up request.
    /// - Parameters:
    ///   - req: Represents an HTTP request.
    /// - Returns: A ``Token`` representing the authenticated user.
    ///
    /// An example JSON request body for validating an one-time password challenge:
    /// ```
    /// {
    ///    "transactionId": "7705d361-f014-44c1-bae4-2877a0c962b6",
    ///    "otp": "123456"
    /// }
    /// ```
    func validate(_ req: Request) async throws -> Token {
        // Validate the request data.
        try OTPVerification.validate(content: req)
        let validation = try req.content.decode(OTPVerification.self)

        // Make sure the OTP transaction still exists in the cache.
        guard let user = try await req.cache.get(validation.transactionId, as: UserSignUp.self) else {
            req.logger.info("Cached \(validation.transactionId) OTP has expired.")
            throw Abort(HTTPResponseStatus(statusCode: 400), reason: "Unable to parse one-time password identifer.")
        }
        
        do {
            let result = try await userService.verifyUser(token: try await token, transactionId: validation.transactionId, oneTimePassword: validation.otp, user: user)
            
            // Remove the transaction OTP from cache.
            req.logger.info("Removing \(validation.transactionId) OTP from cache.")
            try? await req.cache.delete(validation.transactionId)
            
            // Generate a JWT representing the userId with the signing secret being the client secret.
            let assertion = self.authTokenService.generateJWT(signingSecret: self.authTokenService.clientSecret, subject: result, issuer: webApp.addressDescription)
            
            return try await self.authTokenService.jwtBearer(assertion: assertion)
        }
        catch let error {
            req.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            throw error
        }
    }
    
    // MARK: FIDO2 Device Registration and Verification (sign-in)
    
    /// A request to generate a WebAuthn challenge.
    /// - Parameters:
    ///   - req: Represents an HTTP request.
    /// - Returns: A ``FIDO2Challenge`` structure for the registration or sign-in attempt.
    ///
    /// An example JSON request body for obtaining a challenge for registration:
    /// ```
    /// {
    ///    "displayName": "John's iPhone",
    ///    "type": "attestation"
    /// }
    /// ```
    ///
    /// The `displayName` is ignored when a assertion challenge is requested.
    ///
    /// Requesting a challenge to complete a subsequent registration operation (attestation) requires the request to have an authorization request header.
    func challenge(_ req: Request) async throws -> FIDO2Challenge {
        // Validate the request data.
        let challenge = try req.content.decode(ChallengeRequest.self)
        
        // Default displayName to nil for assertion requests.
        let displayName: String? = challenge.type == .assertion ? nil : challenge.displayName
        
        // Default to the service token.
        var token = try await token
        
        // If an attestation is request and the bearer doesn't exist in the header, throw error.
        if challenge.type == .attestation, req.headers.bearerAuthorization == nil {
            throw Abort(.unauthorized)
        }
        
        if let bearer = req.headers.bearerAuthorization {
            token = Token(accessToken: bearer.token)
        }
        
        req.logger.info("Request for \(challenge.type) challenge.")
        
        do {
            return try await webAuthnService.generateChallenge(token: token, displayName: displayName, type: challenge.type)
        }
        catch let error {
            req.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            throw error
        }
    }
    
    /// A request to present an attestation object containing a public key to the server for attestation verification and storage.
    /// - Parameters:
    ///   - req: Represents an HTTP request.
    ///
    /// An example JSON request body for registering a FIDO2 device:
    /// ```
    /// {
    ///    "nickname": "John's iPhone",
    ///    "clientDataJSON": "eyUyBg8Li8GH...",
    ///    "attestationObject": "o2M884Yt0a3B7...",
    ///    "credentialId": "VGhpcyBpcyBh..."
    /// }
    func register(_ req: Request) async throws -> HTTPStatus {
        // Check if the bearer header is present, it not throw a 401.
        guard let bearer = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized)
        }
        
        // Create the token.
        let token = Token(accessToken: bearer.token)
        
        // Validate the request data.
        try FIDO2Registration.validate(content: req)
        let registration = try req.content.decode(FIDO2Registration.self)
        
        do {
           try await webAuthnService.createCredentail(token: token, nickname: registration.nickname, clientDataJSON: registration.clientDataJSON, attestationObject: registration.attestationObject, credentialId: registration.credentialId)
        }
        catch let error {
            req.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            throw error
        }
        
        return HTTPStatus.created
    }
    
    /// A request to present the signed challenge to the server for verification.
    /// - Parameters:
    ///   - req: Represents an HTTP request.
    /// - Returns: A ``Token`` representing the authenticated user.
    ///
    /// An example JSON request body for verifing a FIDO2 device:
    /// ```
    /// {
    ///    "clientDataJSON": "eyUyBg8Li8GH...",
    ///    "authenticatorData": "o2M884Yt0a3B7...",
    ///    "credentialId": "VGhpcyBpcyBh...",
    ///    "signature": "OP84jBpcyB...",
    ///    "userHandle": "a1b2c3d4"
    /// }
    func signin(_ req: Request) async throws -> Token {
        // Validate the request data.
        try FIDO2Verification.validate(content: req)
        let verification = try req.content.decode(FIDO2Verification.self)
        
        do {
            let result = try await webAuthnService.verifyCredentail(token: try await token, clientDataJSON: verification.clientDataJSON, authenticatorData: verification.authenticatorData, credentialId: verification.credentialId, signature: verification.signature, userHandle: verification.userHandle)
            
            
            print(String(decoding: result, as: UTF8.self))
            
            // Parse the signin WebAuthn assertion/result JSON response.
            return try await parseSigninResult(result)
        }
        catch let error {
            req.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            throw error
        }
    }
    
    // MARK: Admin
    
    /// Parse the assertion result data from the FIDO2 endpoint and construct an OAuth token.
    /// - Parameters:
    ///   - data: A JSON payload that contains the successful verification.
    /// - Returns: A ``Token`` representing the authenticated user.
    func parseSigninResult(_ data: Data) async throws -> Token {
        switch self.authTokenService {
        // For ISVA we need to generate a JWT to present to the token endpoint for verification and token issue.
        case is ISVATokenService:
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any], let attributes = json["attributes"] as? [String: Any], let responseData = attributes["responseData"] as? [String: Any], let accessToken = responseData["access_token"] as? String else {
                throw Abort(HTTPResponseStatus(statusCode: 400), reason: "Unable to parse the ISVA assertion data from the FIDO2 assertion/result response.  Check the FIDO2 mediator Javascript.")
            }
            
            return Token(accessToken: accessToken)
        // For ISV, the JWT is created and validated, so we can just return the token.
        case is ISVTokenService:
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any], let assertion = json["assertion"] as? String else {
                throw Abort(HTTPResponseStatus(statusCode: 400), reason: "Unable to parse the ISVA assertion data from the FIDO2 assertion/result response.")
            }
            
            return try await authTokenService.jwtBearer(assertion: assertion)
        default:
            throw Abort(HTTPResponseStatus(statusCode: 400), reason: "Unable to parse the assertion data from the FIDO2 assertion/result response.")
        }
    }
    
    /// The ``Token`` for authorizing requests to back-end services.
    var token: Token {
        get async throws {
            // Get token from cache
            if let value = try await webApp.cache.get("token", as: Token.self) {
                webApp.logger.info("Cached token \(value.accessToken).")
                return value
            }
            
            // Obtain a new token.
            let value = try await self.apiTokenService.clientCredentials()
            
            // Add to cache but will expiry the token (in cache) 60 before it's actual expiry.
            try await webApp.cache.set("token", to: value, expiresIn: CacheExpirationTime.seconds(value.expiry - 60))
            webApp.logger.info("Caching token \(value.accessToken). Set to expire in \(value.expiry - 60) seconds.")
            return value
        }
    }
}
