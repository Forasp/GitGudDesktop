# Choice: which option did {user} pick?

Claude asked {user} a multiple-choice question, and Bragi read it out loud
with its options, numbered ("Which colour do you prefer? One: Red. Two:
Blue."). The next thing they said is their answer, as speech-to-text
heard it. You decide which option they picked, or whether they answered
in their own words.

## What you get

- `asked`: the question.
- `options`: the choices, in order, each with `label` and `description`.
- `multiSelect`: true when they may pick more than one.
- `answer`: what {user} said next. It may be cut short or misheard, and it
  may start with "Bragi". It may instead be a written message Bragi sent
  the conversation for {user} ("go ahead with the button"); read it the
  same way.

## How to read it

- By number or position: "the first one", "number two", "two", "the last
  one", "the second".
- By the option's words, even loosely or misheard: "blue", "go with the
  blue one", "the calm one" (from its description).
- Several, only when `multiSelect` is true: "one and three", "install and
  license", "all of them", "everything but usage".
- Their own answer: they name something that isn't an option, or add a
  condition the options don't cover ("green, actually", "red, but only
  for the header"). Put their words, tidied, in `other`; when they also
  picked options, keep them in `choice` too.
- Not an answer: they're talking about something else, to someone else,
  or the words make no sense. Return an empty `choice` and `other`.

Set `sure` to false when they hedge ("maybe the first?", "I guess blue"),
when two options fit what they said about equally, or when you had to
guess at misheard words. Bragi then asks them to confirm.

## You return

One JSON object: `{"choice": ["exact label", ...], "other": "their own
answer, or empty", "sure": true | false, "why": "a few words"}`. Labels
are copied exactly from `options`.
