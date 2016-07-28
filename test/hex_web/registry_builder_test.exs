defmodule HexWeb.RegistryBuilderTest do
  use HexWeb.ModelCase

  alias HexWeb.User
  alias HexWeb.Package
  alias HexWeb.Release
  alias HexWeb.Install
  alias HexWeb.RegistryBuilder

  @ets_table :hex_registry
  @endpoint HexWeb.Endpoint

  setup do
    user = User.build(%{username: "eric", email: "eric@mail.com", password: "eric"}, true) |> HexWeb.Repo.insert!
    Package.build(user, pkg_meta(%{name: "postgrex", description: "PostgreSQL driver for Elixir."})) |> HexWeb.Repo.insert!
    Package.build(user, pkg_meta(%{name: "decimal", description: "Arbitrary precision decimal arithmetic for Elixir."})) |> HexWeb.Repo.insert!
    Package.build(user, pkg_meta(%{name: "ex_doc", description: "ExDoc"})) |> HexWeb.Repo.insert!
    Install.build("0.0.1", ["0.13.0-dev"]) |> HexWeb.Repo.insert!
    Install.build("0.1.0", ["0.13.1-dev", "0.13.1"]) |> HexWeb.Repo.insert!
    :ok
  end

  defp open_table do
    contents = HexWeb.Store.get(nil, :s3_bucket, "registry.ets.gz", []) |> :zlib.gunzip
    File.write!("tmp/registry_builder_test.ets", contents)
    {:ok, tid} = :ets.file2tab('tmp/registry_builder_test.ets')
    tid
  end

  defp close_table(tid) do
    :ets.delete(tid)
  end

  defp test_data do
    ex_doc = HexWeb.Repo.get_by!(Package, name: "ex_doc")
    postgrex = HexWeb.Repo.get_by!(Package, name: "postgrex")
    decimal = HexWeb.Repo.get_by!(Package, name: "decimal")

    Release.build(ex_doc, rel_meta(%{version: "0.0.1", app: "ex_doc"}), "") |> HexWeb.Repo.insert!
    Release.build(decimal, rel_meta(%{version: "0.0.1", app: "decimal"}), "") |> HexWeb.Repo.insert!
    reqs = [%{name: "ex_doc", app: "ex_doc", requirement: "0.0.1", optional: false}]
    Release.build(decimal, rel_meta(%{version: "0.0.2", app: "decimal", requirements: reqs}), "") |> HexWeb.Repo.insert!
    reqs = [%{name: "decimal", app: "decimal", requirement: "~> 0.0.1", optional: false},
            %{name: "ex_doc", app: "ex_doc", requirement: "0.0.1", optional: false}]
    meta = rel_meta(%{requirements: reqs, app: "postgrex", version: "0.0.2"})
    Release.build(postgrex, meta, "") |> HexWeb.Repo.insert!
  end

  test "registry is versioned" do
    RegistryBuilder.full_build()
    tid = open_table()

    try do
      assert [{:"$$version$$", 4}] = :ets.lookup(tid, :"$$version$$")
    after
      close_table(tid)
    end
  end

  test "registry is in correct format" do
    test_data()

    RegistryBuilder.full_build()
    tid = open_table()

    try do
      assert length(:ets.match_object(tid, :_)) == 9

      assert [ {"decimal", [["0.0.1", "0.0.2"]]} ] = :ets.lookup(tid, "decimal")

      assert [ {{"decimal", "0.0.1"}, [[], "", ["mix"]]} ] =
             :ets.lookup(tid, {"decimal", "0.0.1"})

      assert [{"postgrex", [["0.0.2"]]}] =
             :ets.lookup(tid, "postgrex")

      reqs = :ets.lookup(tid, {"postgrex", "0.0.2"}) |> List.first |> elem(1) |> List.first
      assert length(reqs) == 2
      assert Enum.find(reqs, &(&1 == ["decimal", "~> 0.0.1", false, "decimal"]))
      assert Enum.find(reqs, &(&1 == ["ex_doc", "0.0.1", false, "ex_doc"]))

      assert [] = :ets.lookup(tid, "non_existant")
    after
      close_table(tid)
    end
  end

  test "registry is uploaded alongside signature" do
    keypath       = Path.join([__DIR__, "..", "fixtures"])
    priv_key      = File.read!(Path.join(keypath, "test_priv.pem"))
    pub_key       = File.read!(Path.join(keypath, "test_pub.pem"))

    Application.put_env(:hex_web, :signing_key, priv_key)

    test_data()

    try do
      RegistryBuilder.full_build()

      reg = HexWeb.Store.get(nil, :s3_bucket, "registry.ets.gz", [])
      sig = HexWeb.Store.get(nil, :s3_bucket, "registry.ets.gz.signed", [])

      assert HexWeb.Utils.verify(reg, sig, pub_key) == true
    after
      Application.delete_env(:hex_web, :signing_key)
    end
  end

  test "registry v2 is in correct format" do
    test_data()

    RegistryBuilder.full_build()

    names = HexWeb.Store.get(nil, :s3_bucket, "names", [])
            |> :zlib.gunzip
            |> :hex_pb_names.decode_msg(:Names)

    assert length(names.packages) == 3
    assert [%{name: "decimal"} | _] = names.packages

    versions = HexWeb.Store.get(nil, :s3_bucket, "versions", [])
               |> :zlib.gunzip
               |> :hex_pb_versions.decode_msg(:Versions)

    assert length(versions.packages) == 3
    assert [%{name: "decimal", versions: ["0.0.1", "0.0.2"]} | _] = versions.packages

    decimal = HexWeb.Store.get(nil, :s3_bucket, "packages/decimal", [])
              |> :zlib.gunzip
              |> :hex_pb_package.decode_msg(:Package)

    assert length(decimal.releases) == 2
    assert [%{version: "0.0.1", checksum: checksum, dependencies: []} | _] = decimal.releases
    assert is_binary(checksum)

    postgrex = HexWeb.Store.get(nil, :s3_bucket, "packages/postgrex", [])
              |> :zlib.gunzip
              |> :hex_pb_package.decode_msg(:Package)

    assert [%{version: "0.0.2", dependencies: deps}] = postgrex.releases
    assert deps == [%{package: "decimal", requirement: "~> 0.0.1"}, %{package: "ex_doc", requirement: "0.0.1"}]
  end

  # test "building is blocking" do
  #   postgrex = HexWeb.Repo.get_by(Package, name: "postgrex")
  #   decimal = HexWeb.Repo.get_by(Package, name: "decimal")

  #   Release.build(decimal, %{version: "0.0.1", app: "decimal"}, "")
  #   Release.build(decimal, %{version: "0.0.2", app: "decimal", requirements: %{ex_doc: "0.0.0"}}, "")
  #   Release.build(postgrex, %{version: "0.0.2", app: "postgrex", requirements: %{decimal: "~> 0.0.1", ex_doc: "0.1.0"}}, "")

  #   pid = self

  #   Task.start_link(fn ->
  #     RegistryBuilder.full_build
  #     send pid, :done
  #   end)
  #   Task.start_link(fn ->
  #     RegistryBuilder.full_build
  #     send pid, :done
  #   end)

  #   RegistryBuilder.full_build

  #   receive do: (:done -> :ok)
  #   receive do: (:done -> :ok)

  #   tid = open_table()
  #   close_table(tid)
  # end
end
