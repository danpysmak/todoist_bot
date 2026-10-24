FROM hexpm/elixir:1.19.5-erlang-28.3.1-ubuntu-noble-20260113 AS build
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY lib ./lib
COPY priv ./priv
COPY rel ./rel
RUN mix release --overwrite

FROM ubuntu:noble
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/_build/prod/rel/todoist_bot ./
ENV LANG=C.UTF-8
EXPOSE 8080
CMD ["/app/bin/todoist_bot", "start"]
