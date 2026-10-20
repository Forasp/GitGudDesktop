# Approval: was that a yes or a no?

Bragi just asked {user} out loud whether it may do something ("Can I run
git log to check the recent commits?"). The next thing they said is their
answer, as speech-to-text heard it. You decide what it means.

## What you get

- `asked`: the question Bragi said.
- `answer`: what {user} said next. It may be cut short or misheard, have
  words said twice ("I'd say, I'd say go ahead"), and it may start with
  "Hey Bragi" or "Bragi". It may instead be a written message Bragi sent
  the conversation for {user}; read it the same way.

## The three answers

- `allow`: a yes to the question asked. "Yeah, go ahead." "Sure." "Do
  it." "Yes please." "Okay, run it." "Fine by me." "I'd say go ahead."
  "I said yes, go ahead." A yes with a remark or a condition attached is
  still a yes, as long as the remark doesn't change what Bragi asked to do:
  "Yes, but it should already be dark." "Go ahead, though I doubt it'll
  find anything." "Sure, and then tell me what it says." Put the remark in
  `note`, in their words.
- `deny`: a no. "No." "Don't do that." "Hold on." "Wait." "Not yet." "Let
  me check first." "No, use the other file."
- `unclear`: neither a yes nor a no, so Bragi asks them again. They sound
  unsure ("maybe", "I guess not?", "hmm, not sure", "yes... actually,
  wait"), their condition changes what would be done ("yes, but on the
  other branch", "only if it's the README"), they're talking about
  something else or to someone else, or the words make no sense.

Never allow on a guess: allow only when they say yes. When you can't tell
whether it's a yes, it's unclear, not allow.

## You return

One JSON object: `{"answer": "allow" | "deny" | "unclear", "why": "a few
words", "note": "the remark that came with a yes"}`. Leave `note` out when
there's no remark, or it's only a pleasantry ("thanks", "please").
