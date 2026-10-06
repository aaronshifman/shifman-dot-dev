---
title: Joining the Mile High (Code) Club"
date: 2026-10-05T22:56:16Z
draft: true
description: "A full dev environment at 35000 feet"
---

I'm on my honeymoon, we're going to Australia as a correlary I'm trapped in a small metal tube going two thirds the speed of sound for almost 24 whole hour, with only a small layover to tide me over.

I'm no stranger to flying and can generally entertain myself for a few hours, but 24... I can't entertain myself for 24 hours at home. I'm not bringing my laptop to prevent the temptation of working. This also means no code pet-projects to work on while on the plane.But I had this (possibly) dumb idea; what if I could spin up a dev env in my Kubernetes cluster and connect remotely from the plane. All I need is ssh, right?

# The Dev Environmet
This idea piggybacks on top of something I had already been thinking about for some number of years. Everything I work on is ultimately just code in a cli and services in docker-compose for testing. Why do I even need a computer, I just need a keyboard. The computer can be elsewhere.

Is there a mechanism by which my computer can just be a dumb shell and connect to an ephemoral environemtn in the `cloud` (picture some jazz hands right about now). Turns out I'm not the only person to have thought of this before, and in fact someones already made it [coder](https://coder.ai) is basically that. Yeah it's made for "AgEnTs" but at it's core it's exactly what I want.

Internally coder lets me define a dev environemnt in terraform HCL, and it just applies it, which means that I can use it to spin up a pod in Kubernetes that is controlled by coder, and when I don't want the environment any more I can shoot it in the face and it's like I was never there.

## Secrets + Config
One this that this needs is secrets, at a minimum I need to connect to Github to pull my repos. Coder does this neat thing where for each user in coder, it'll provision an SSH key so all I need to do is add the public key to Github and coder auto configures git on the environment to use _your_ key.

For other secrets, I can add them to coder directly and it'll auto mount them as env vars in the environment

# The connection
I've got my IPad which means I'm limited to a web code-editor :barf: or ssh. Talscale has this lovely native feature called tailscale-ssh. Basically it uses my tailscale identity on the tailnet to authorize a connection to an ssh-like server running on the host server.

So the plan is in the base image that I use for the enviromnet, I'll bake tailscale into it, configure the tailscale auth key in coder (it gets injected by coder), and in an init script run `tailscale up --ssh`.

## Womp Womp Intensifies
Womp, womp. Turns out that can never work. Coder ingects the secrets based on the ssh connection and identity, and importantly it's based on the coder identitiy, not the tailscale identity. The blessedpath with coder is `coder config-ssh` and `ssh some-workspace`. Now this is not what it seems, if we inspect the ssh config

```bash
Host coder.*
        ProxyCommand /usr/local/bin/coder --global-config /tmp/coderv2 ssh --stdio --ssh-host-prefix coder. %h

Match host *.coder !exec "/usr/local/bin/coder connect exists %h"
        ProxyCommand /usr/local/bin/coder --global-config /tmp/coderv2 ssh --stdio --hostname-suffix coder %h
```

Coder is doing some shenanigains. I don't know the details, but it wouild appear that you're not ssh-ing into the workspace. You're talking with coder and it configures somet hings in the control plane. As we'll come to see later, communicating via "ssh" to the coder environment does not require direct access to the environment. My guess is that the control plane isproxying the connection to the ephemoral environemtn.

So the solution is a tal as old as time. I can't run the coder cli on the iPad to configure the ssh magic, but I can ssh into something that can. Enter the jump-host. I've deployed a small jumphost with a simple image that containes the coder and tailscale binaries, as well as the corresponding API keys. On start the jump host connects to both tailscale and coder. I can ssh into the jumphost over tailscale on the ipad. I can use coder on the jumphost to connect to the enviroment. And since I connect over coder, my identity, secrets, and even dotfiles come pre-configured.

This is how I know coder is doing some shenanigains, I have network policies allowing the workspace to talk to coder, and for the jump host to talk to coder. But no netowrk policy allows communication from the jumphost to the dev env.

# Does It work?
I'm currently somewhere voer the pacific ocean with nothing to do but write this, the actual markdown file is sitting on a PVC in kubernetes 1/3 across the world.

But I suppose the larger question is... does it work, well? Absolutely not, in fact I'd go as far to say this is one of the worst developer experinces I've ever encountered (and one upod a time I'd copy files over to an apache 2 server and hit the big restart button). Airplan wifi is (tehnical term incomming) Doodoo, I'm on a derp-relayed connection with a 1500ms ping time. Every character is a lag to type. Its the sort of environment where vim motions are _required_ because `dap` is three characters and highlighting an entire paragraph to delete is way more.

Could this be practical in a coffee shop, or a town a few hours away? Totally plausible. Is this practical in a plane? Good god no.

# Addendum

This doesn't really fit the main story, but it's too cool not to share. I realized too-little too late that my jumphost was rebooting... idk why but I suspect it was a memory limit. I could log into Github, edit the deployment for the jumphost to bump it's resource limits (some dummy gave it a mmeory limit of 128Mi), open a PR. My CI picked it up, rendered teh diff just to make sure nothing's malformed. Merge it, Github sends a webhook to my argocd instance which rolls-out a new pod with the updated limits and the restarts are solved.

Modern infrastructure is a marvel, and we should all appreciate it more.
