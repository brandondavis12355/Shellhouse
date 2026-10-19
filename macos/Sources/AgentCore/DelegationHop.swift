/// How far a `message_bot` call may go. The bot that was asked may check with one
/// other bot. That second bot cannot pass the question on, and a hop never waits
/// on the original asker or on a bot that is already busy.
public enum DelegationHop {
    public enum Reason: String, Sendable, Equatable {
        case origin
        case busy
        case passedOn
    }

    public enum Decision: Sendable, Equatable {
        /// `allowFurther` is true only for the first ask, so the recipient may make one hop.
        case run(allowFurther: Bool)
        case skip(Reason)
    }

    public static func decision(hop: Int, recipientID: String, originID: String?, recipientBusy: Bool) -> Decision {
        if hop <= 0 { return .run(allowFurther: true) }
        if hop >= 2 { return .skip(.passedOn) }
        if let originID, recipientID == originID { return .skip(.origin) }
        if recipientBusy { return .skip(.busy) }
        return .run(allowFurther: false)
    }
}
