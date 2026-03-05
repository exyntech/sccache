FROM rust:1.93-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release && strip target/release/sccache

FROM scratch
COPY --from=build /src/target/release/sccache /sccache
