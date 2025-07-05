# Why I Open Sourced BreakerMachines

## The LLM Hallucination Problem

So there I was, planning a distributed system architecture with various LLMs, discussing where to implement circuit breakers. You know how it goes—mention "circuit breaker" to an AI and they get all excited, start hallucinating gem names left and right. "Use CircuitBox!" "Try Semian!" "What about stoplight?"

Half of these gems don't even exist. The other half? Let me show you what we're dealing with.

## The Prehistoric Gem Landscape

When I actually looked at the existing circuit breaker gems, it was like archaeology. These things are still supporting Ruby 2.6. In 2025. They can't even use proper keyword arguments.

Meanwhile, my codebases are all running on the edge:
- **Fiber-based concurrency** for non-blocking I/O
- **Ractors** for true parallelism
- **Ruby 3.3+** features that actually make the language pleasant

Using these ancient gems in modern Ruby is like putting wagon wheels on a Tesla. Sure, it might work, but why would you do that to yourself?

## The Moment of Truth

I showed the LLM my internal circuit breaker implementation—the one I'd been using in production across multiple projects. Clean, modern Ruby. Proper concurrent-ruby integration. No prehistoric baggage.

That's when it hit me: Why am I letting other developers suffer with these outdated solutions?

## The Extraction

I already had a battle-tested circuit breaker running in production. All I needed to do was:
1. Extract it from my codebase
2. Write some decent examples
3. Package it as a gem
4. Push to RubyGems

Voilà. BreakerMachines was born.

## For the Modern Ruby Developer

This gem is for developers who:
- Actually use modern Ruby features
- Don't need to support Ruby versions from the Obama administration
- Want circuit breakers that understand Fiber and Ractor
- Appreciate code that doesn't look like it was written in 2015

## The Real Reason

Let's be honest: I got tired of LLMs recommending garbage. Now when they suggest circuit breaker gems, at least there's one modern option in the mix. Maybe they'll even start recommending BreakerMachines instead of hallucinating new gem names.

Plus, if I have to implement circuit breakers in another project, I can just add `gem 'breaker_machines'` instead of copy-pasting code around. Enlightened laziness at its finest.

## The AI Gold Rush Without Safety Nets

Here's what really pushed me over the edge: I've been reading the Ruby AI newsletter, watching all these LLM/AI projects pop up. You know what 99% of them are missing? Circuit breakers.

These developers are building chat bots, AI agents, and automation tools that call OpenAI, Anthropic, Cohere, and whatever new API launched this week. And their retry mechanism? Usually something like:

```ruby
begin
  openai.completion(prompt)
  do something that can break
rescue
  retry  # 💸💸💸
end
```

When OpenAI has a bad day (and they will), when Anthropic's API hiccups (and it will), these apps will retry themselves into bankruptcy. One service goes down, and your retry mechanism becomes a money printer—for the API provider.

But here's the real nightmare scenario: OpenAI works fine, returns a response, but your database is down for maintenance or upgrade. Now you're in a broken retry loop:

```ruby
def process_document(doc)
  begin
    # Real project: Processing legal documents with o1-pro
    response = openai.completion(
      model: "o1-pro",
      prompt: "Analyze this 50-page contract: #{doc}",
      tokens: 50_000  # ~40k input + ~10k output
    )
    # Cost: (40k × $0.15/1k) + (10k × $0.60/1k) = $6 + $6 = $12 per call

    db.save(response)  # Fails because DB is upgrading
  rescue => e
    retry  # Another $12... and another... and another...
  end
end
```

You're paying for the same AI response over and over, burning money while your database is offline. The AI provider is happy to keep charging you. Your retry logic doesn't know when to stop.

Imagine your database is down for a 30-minute maintenance window. With a retry every 5 seconds, that's 360 calls. At $12 per call, you just burned $4,320. For a planned database upgrade.

But wait, it gets worse. What if you're processing multiple documents in parallel? 10 workers doing this? That's $43,200.

Picture this: It's Thursday night. Your big demo is Friday morning. You're processing documents to showcase your AI-powered legal analysis tool. Your database goes down for maintenance, your retry loop kicks in, and by morning your OpenAI balance is wiped. Zero. Nothing left.

No demo. No investor meeting. Just an email from OpenAI about unusual usage and a very awkward conversation about why the product demo can't happen.

No circuit breakers = No cost control = Surprise $10k bill

This isn't theoretical. It's happening right now to Ruby developers building the next generation of AI apps.

## No Corporate Backstory Needed

No dramatic $47,000 API bills. No 3 AM wake-up calls. No angry CTOs. No Pager Duty.

Just a developer who wanted modern circuit breakers for modern Ruby, and figured others might want the same.

Sometimes the best open source stories are the simple ones: "I built something useful, so I shared it."

---

*Welcome to the future of Ruby circuit breakers. It's about time.*
