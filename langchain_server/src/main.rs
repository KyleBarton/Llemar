// use llm_chain::{chains::conversation::Chain, executor, parameters, prompt, step::Step};

// #[tokio::main(flavor = "current_thread")]
// async fn main() -> Result<(), Box<dyn std::error::Error>> {
//   // Create a new ChatGPT executor.
//   let exec = executor!()?;

//   let params = parameters!();

//   // Create a new Chain with the executor.
//   let mut chain = Chain::new(
//     prompt!(system: "You are a robot assistant helping me to better understand your API."),
//   )?;

//   // Define the conversation steps.
//   let first_msg = Step::for_prompt_template(prompt!(user: "Hi, my name is Kyle. Please make up a name for me to call you."));
//   // Execute the conversation steps.
//   let first_resp = chain.send_message(first_msg, &parameters!(), &exec).await?;
//   println!("Response 1: {}", first_resp.to_immediate().await?);

//   let next_msg = Step::for_prompt_template(prompt!(user: "What have you asked me to call you?"));
//   let next_resp = chain.send_message(next_msg, &parameters!(), &exec).await?;
//   println!("Response 2: {}", next_resp.to_immediate().await?);

//   Ok(())
// }

use llm_chain::options::{ModelRef, Options, OptionsBuilder};
// What about sequential?
use llm_chain::parameters;
use llm_chain::step::Step;
use llm_chain::traits::Executor as ExecutorTrait;
use llm_chain::{chains::sequential::Chain, prompt};
use llm_chain_openai::chatgpt::Executor;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
  // Create a new ChatGPT executor with the default settings
  let mut bldr = OptionsBuilder::default();
  bldr.add_option(llm_chain::options::Opt::MaxTokens(10));
  bldr.add_option(llm_chain::options::Opt::Model(ModelRef::from_model_name("gpt-4o")));
  let options = bldr.build();
  let exec = Executor::new_with_options(options)?;

  // Create a chain of steps with two prompts
  let chain: Chain = Chain::new(vec![
    // First step: make a personalized birthday email
    Step::for_prompt_template(
      prompt!("You are a bot for making personalized greetings", "Make personalized birthday e-mail to the whole company for {{name}} who has their birthday on {{date}}. Include their name, and make it minimum 500 words.")
    ),

    // Second step: summarize the email into a tweet. Importantly, the text parameter becomes the result of the previous prompt.
    Step::for_prompt_template(
      prompt!( "You are an assistant for managing social media accounts for a company", "Summarize this email into a tweet to be sent by the company, use emoji if you can. \n--\n{{text}}. Additionally, show me the whole email you created.")
    )
  ]);

  // Run the chain with the provided parameters
  let res = chain
    .run(
      // Create a Parameters object with key-value pairs for the placeholders
      parameters!("name" => "Emil", "date" => "February 30th 2023"),
      &exec,
    )
    .await
    .unwrap();

  // Print the result to the console
  println!("{}", res.to_immediate().await?.as_content());
  Ok(())
}
