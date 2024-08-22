# Llemar
An LL(m) ema(cs) r(epl)


## Goals of the project

- emacs major mode as a front end/porcelain
- langchain as a "backend" to keep things llm agnostic
- Local resources
  - Local RAGs
  - Local logs of conversations
  - etc
- Software can be produced and self-deployed
  - Related: dogfood this system as soon as possible


## Non-goals
- Language agnosticism: we're doing emacs & python in all likelihood
- Generalization: this is a personalized project for my own workflow


## Next steps:

1. Move from all emacs to langchain/python backend
   1. As part of that, handle token-limit responses with either streaming or subsequent API calls
2. Formalize the prompt and structured responses
   1. Additionally, prompt should be configurable?
3. Start down the road to self-editing
