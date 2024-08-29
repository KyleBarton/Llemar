use std::fs;

use langchain_rust::{
  chain::{Chain, LLMChainBuilder}, fmt_message, fmt_placeholder, fmt_template, language_models::llm::LLM, llm::openai::{OpenAI, OpenAIModel}, message_formatter, prompt::{FormatPrompter, HumanMessagePromptTemplate}, prompt_args, schemas::messages::Message, template_fstring
};

#[tokio::main]
async fn main() {
  // Set up some logging.
  simplelog::WriteLogger::init(
    simplelog::LevelFilter::Debug,
    simplelog::Config::default(),
    fs::File::create("llm.log").unwrap(),
  ).unwrap();


  let open_ai = OpenAI::default().with_model(OpenAIModel::Gpt4o.to_string());
  let prompt = message_formatter![
    fmt_message!(Message::new_system_message(
      "You are world class technical documentation writer."
    )),
    fmt_placeholder!("history"),
    fmt_template!(HumanMessagePromptTemplate::new(template_fstring!(
      "{input}", "input"
    ))),
  ];

  let prompt_args = prompt_args! {
    "input" => "According to our chat history, when I introduced myself, how did you respond? Please respond clearly without judging the accuracy of that previous response.",
    "history" => vec![
      Message::new_human_message("My name is kyle"),
      Message::new_ai_message("Hi there Kyle, you can call me bob"),
    ],
  };

  let msg = &prompt.format_prompt(prompt_args.clone()).unwrap();

  // open_ai.messages_to_string(msg);
  println!("{:?}", open_ai.messages_to_string(&msg.to_chat_messages()));

  let chain = LLMChainBuilder::new()
    .prompt(prompt)
    .llm(open_ai)
    .build()
    .unwrap();
  // match chain
  //   .invoke(prompt_args! {
  //     "input" => "Who is the writer of 20,000 Leagues Under the Sea, and what is my name?",
  //     "history" => vec![
  //       Message::new_human_message("My name is: luis"),
  //       Message::new_ai_message("Hi luis"),
  //     ],

  //   })
  //   .await
  // {
  //   Ok(result) => {
  //     println!("Result: {:?}", result);
  //   }
  //   Err(e) => panic!("Error invoking LLMChain: {:?}", e),
  // }

  match chain
    .invoke(prompt_args).await {
      Ok(result) => {
	println!("Result: {}", result)
      }
      Err(_) => panic!("Couldn't reflect prompt back")
    }
}
