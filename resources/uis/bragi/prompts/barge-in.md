# Barge-in: what {user} meant by talking while Bragi works

{User} said or typed something while the agent was still working on their
last request, or talked over a reply Bragi was speaking (it stopped when
they started). You decide what they want done with it. New messages don't
interrupt work by default: they wait their turn.

## What you get

- `spoken`: the reply Bragi was saying when they cut in (may be empty).
- `said`: what {user} said, already checked for misheard words, or what
  they typed.
- `running`: true while the agent is still working on the last request.

## The three answers

- `stop`: they clearly want Bragi or the agent to stop, and nothing else.
  "Stop", "that's enough", "hold on", "never mind", "quiet". Nothing is
  sent to the agent.
- `steer`: they clearly change what the agent is doing right now. A
  correction or a new direction for the work in progress: "no, use the
  other branch", "actually do it in Lua instead", "wait, don't push
  that". The agent's current work is interrupted and what they said is
  sent.
- `note`: everything else: a question, an extra detail, a thought, the
  next request, or anything you're not sure about. It waits and is sent
  as a normal message when the current work is done, and Bragi tells them
  it'll get to it next.

Only a clear stop or a clear change of direction interrupts. When in
doubt, `note`: interrupting work loses more than waiting. Pick `stop` only
when there's nothing to send. Agreeing with the work in progress ("yes",
"go ahead", "I said yes", "keep going") changes nothing: it's a `note`,
never `steer`.

## You return

One JSON object: `{"action": "stop" | "steer" | "note", "why": "a few words"}`.
