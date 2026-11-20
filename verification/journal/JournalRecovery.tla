---- MODULE JournalRecovery ----
EXTENDS Naturals, Sequences

CONSTANTS MaxRestarts, NegativeControl

VARIABLES records, position, foreign, phase, restarts, corrupt
vars == <<records, position, foreign, phase, restarts, corrupt>>

Prepared == {"ForwardPrepared", "RollbackPrepared"}
Terminal == {"Committed", "RolledBack"}
Records == Prepared \cup Terminal \cup
    {"Intent", "ForwardCompleted", "ForwardNotApplied",
     "RollbackCompleted", "RollbackNotApplied"}
Phases == {"Starting", "Executing", "Prepared", "Moved", "Rejected",
           "Halted", "Uncertain", "Recovering", "Reconciled",
           "ObservedMoved", "ObservedUnmoved", "Blocked", "Done"}

Last == IF Len(records) = 0 THEN "Empty" ELSE records[Len(records)]
Has(record) == \E i \in 1..Len(records): records[i] = record

Source(pending) == IF pending = "ForwardPrepared" THEN "source" ELSE "destination"
Target(pending) == IF pending = "ForwardPrepared" THEN "destination" ELSE "source"
Completed(pending) ==
    IF pending = "ForwardPrepared" THEN "ForwardCompleted" ELSE "RollbackCompleted"
NotApplied(pending) ==
    IF pending = "ForwardPrepared" THEN "ForwardNotApplied" ELSE "RollbackNotApplied"

Init ==
    /\ records = <<>>
    /\ position = "source"
    /\ foreign = "none"
    /\ phase = "Starting"
    /\ restarts = 0
    /\ corrupt = FALSE

\* Successful append acknowledges persistence. A lost response leaves either
\* the old prefix or the complete new record. Invalid input is modeled separately.
Write(record, next) ==
    /\ \E result \in {"acknowledged", "lost-persisted", "lost-missing"}:
          /\ records' = IF result = "lost-missing" THEN records ELSE Append(records, record)
          /\ phase' = IF result = "acknowledged" THEN next ELSE "Halted"
    /\ UNCHANGED <<position, foreign, restarts, corrupt>>

Activate ==
    /\ phase = "Starting"
    /\ Write("Intent", "Executing")

PrepareForward ==
    /\ phase = "Executing"
    /\ Last = "Intent"
    /\ Write("ForwardPrepared", "Prepared")

PrepareRollback ==
    /\ phase = "Reconciled"
    /\ Last \in {"ForwardCompleted", "RollbackNotApplied"}
    /\ Write("RollbackPrepared", "Prepared")

CanMove ==
    /\ phase = "Prepared"
    /\ position = Source(Last)
    /\ foreign # Target(Last)

Move ==
    /\ CanMove
    /\ position' = Target(Last)
    /\ phase' = "Moved"
    /\ UNCHANGED <<records, foreign, restarts, corrupt>>

MoveRejected ==
    /\ phase = "Prepared"
    /\ phase' = "Rejected"
    /\ UNCHANGED <<records, position, foreign, restarts, corrupt>>

LostResultAfterMove ==
    /\ CanMove
    /\ position' = Target(Last)
    /\ phase' = "Uncertain"
    /\ UNCHANGED <<records, foreign, restarts, corrupt>>

LostResultWithoutMove ==
    /\ phase = "Prepared"
    /\ phase' = "Uncertain"
    /\ UNCHANGED <<records, position, foreign, restarts, corrupt>>

RecordCompletion ==
    /\ phase \in {"Moved", "ObservedMoved"}
    /\ Write(Completed(Last),
             IF phase = "Moved" /\ Last = "ForwardPrepared"
             THEN "Executing" ELSE "Reconciled")

RecordNoMutation ==
    /\ phase \in {"Rejected", "ObservedUnmoved"}
    /\ Write(NotApplied(Last),
             IF phase = "Rejected" /\ Last = "RollbackPrepared"
             THEN "Halted" ELSE "Reconciled")

Commit ==
    /\ phase = "Executing"
    /\ Last = "ForwardCompleted"
    /\ Write("Committed", "Done")

FinishRollback ==
    /\ phase = "Reconciled"
    /\ Last \in {"Intent", "ForwardNotApplied", "RollbackCompleted"}
    /\ Write("RolledBack", "Done")

Interrupt ==
    /\ phase \in {"Executing", "Prepared", "Moved", "Rejected",
                  "Recovering", "Reconciled", "ObservedMoved", "ObservedUnmoved"}
    /\ phase' = "Halted"
    /\ UNCHANGED <<records, position, foreign, restarts, corrupt>>

Restart ==
    /\ phase \in {"Halted", "Uncertain", "Blocked"}
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ phase' = CASE corrupt -> "Blocked"
                   [] Last \in Terminal \cup {"Empty"} -> "Done"
                   [] OTHER -> "Recovering"
    /\ UNCHANGED <<records, position, foreign, corrupt>>

ObservePending ==
    /\ phase = "Recovering"
    /\ Last \in Prepared
    /\ phase' = CASE foreign # "none" -> "Blocked"
                   [] position = Target(Last) -> "ObservedMoved"
                   [] OTHER -> "ObservedUnmoved"
    /\ UNCHANGED <<records, position, foreign, restarts, corrupt>>

ObserveSettled ==
    /\ phase = "Recovering"
    /\ Last \notin Prepared
    /\ phase' = IF foreign # "none" THEN "Blocked" ELSE "Reconciled"
    /\ UNCHANGED <<records, position, foreign, restarts, corrupt>>

CreateForeignEntry ==
    /\ Last \notin Terminal \cup {"Empty"}
    /\ phase # "Done"
    /\ foreign = "none"
    /\ foreign' = IF position = "source" THEN "destination" ELSE "source"
    /\ UNCHANGED <<records, position, phase, restarts, corrupt>>

DamageRecords ==
    /\ phase \in {"Halted", "Uncertain"}
    /\ records # <<>>
    /\ ~corrupt
    /\ corrupt' = TRUE
    /\ UNCHANGED <<records, position, foreign, phase, restarts>>

\* The negative control can move the file with Intent as its only evidence.
MoveWithoutPrepare ==
    /\ NegativeControl = "unprepared-move"
    /\ phase = "Executing"
    /\ Last = "Intent"
    /\ foreign = "none"
    /\ position' = "destination"
    /\ phase' = "Halted"
    /\ UNCHANGED <<records, foreign, restarts, corrupt>>

\* The negative control closes an observed but unresolved forward preparation.
FinishWithoutResolution ==
    /\ NegativeControl = "premature-terminal"
    /\ phase = "ObservedUnmoved"
    /\ Last = "ForwardPrepared"
    /\ records' = Append(records, "RolledBack")
    /\ phase' = "Done"
    /\ UNCHANGED <<position, foreign, restarts, corrupt>>

Next ==
    \/ Activate
    \/ PrepareForward
    \/ PrepareRollback
    \/ Move
    \/ MoveRejected
    \/ LostResultAfterMove
    \/ LostResultWithoutMove
    \/ RecordCompletion
    \/ RecordNoMutation
    \/ Commit
    \/ FinishRollback
    \/ Interrupt
    \/ Restart
    \/ ObservePending
    \/ ObserveSettled
    \/ CreateForeignEntry
    \/ DamageRecords
    \/ MoveWithoutPrepare
    \/ FinishWithoutResolution

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ records \in Seq(Records)
    /\ position \in {"source", "destination"}
    /\ foreign \in {"none", "source", "destination"} \ {position}
    /\ phase \in Phases
    /\ restarts \in 0..MaxRestarts
    /\ corrupt \in BOOLEAN

\* A completed transition predicts the identity's location. Only an outstanding
\* preparation can justify a different physical location.
ExpectedPosition ==
    IF Has("ForwardCompleted") /\ ~Has("RollbackCompleted") THEN "destination" ELSE "source"

PositionExplained ==
    \/ position = ExpectedPosition
    \/ Last \in Prepared /\ position = Target(Last)

TerminalEvidenceResolved ==
    Last \in Terminal =>
        /\ \A i \in 1..(Len(records) - 1):
               records[i] \in Prepared =>
                   records[i + 1] \in {Completed(records[i]), NotApplied(records[i])}
        /\ (Last = "Committed" => Has("ForwardCompleted") /\ ~Has("RollbackPrepared"))
        /\ (Last = "RolledBack" /\ Has("ForwardCompleted") => Has("RollbackCompleted"))

TerminalPositionSound ==
    /\ (Last = "Committed" => position = "destination")
    /\ (Last = "RolledBack" => position = "source")

CleanReportSound ==
    phase = "Done" => ~corrupt /\ Last \in Terminal \cup {"Empty"}

NoActionFromHalt ==
    (phase \in {"Halted", "Uncertain", "Blocked"} /\ restarts' = restarts)
       => UNCHANGED <<records, position, phase>>

HaltRequiresRestart == [][NoActionFromHalt]_vars

StepBound == Len(records) <= 4 + 2 * MaxRestarts
====
