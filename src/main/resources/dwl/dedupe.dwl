%dw 2.0
// =====================================================================
// Deduplicate exported leads by email and separate the rejects.
// Input : payload = Array of lead objects from the Marketo export CSV
//         (fields: firstName,lastName,email,company,country)
// Output: { valid:  [ one winner per unique, valid email ],
//           errors: [ rejected rows, each with a failureReason ] }
//
// Rules:
//  - INVALID_EMAIL  : email missing or not a valid address  -> error
//  - DUPLICATE_EMAIL: same email seen more than once; winner = the most
//                     complete record (most non-empty fields), ties keep the
//                     first seen. Every other copy -> error.
// (Meta keys are named rowIdx/emailKey - DataWeave identifiers may NOT start
//  with an underscore.)
// =====================================================================
output application/java

fun norm(r)       = lower(trim(r.email default ""))
fun validEmail(e) = e matches /^[^@\s]+@[^@\s]+\.[^@\s]+$/
fun filled(r)     = sizeOf((r - "rowIdx" - "emailKey") filterObject ((v) -> not isEmpty(v)))
fun clean(r)      = r - "rowIdx" - "emailKey"

// tag each row with its original position and a normalised email
var tagged      = payload map ((r, i) -> r ++ { rowIdx: i, emailKey: norm(r) })
var validRows   = tagged filter ((r) -> validEmail(r.emailKey))
var invalidRows = tagged filter ((r) -> not validEmail(r.emailKey))

// winner per email = most complete record (stable tie-break keeps first seen)
var winners    = (validRows groupBy ((r) -> r.emailKey))
                    pluck ((recs, email) -> (recs orderBy ((r) -> filled(r)))[-1])
var winnerIdx  = winners map ((w) -> w.rowIdx)
var duplicates = validRows filter ((r) -> not (winnerIdx contains r.rowIdx))
---
{
    valid: winners map ((r) -> clean(r)),
    errors:
        (invalidRows map ((r) -> clean(r) ++ { failureReason: "INVALID_EMAIL"   }))
     ++ (duplicates  map ((r) -> clean(r) ++ { failureReason: "DUPLICATE_EMAIL" }))
}
