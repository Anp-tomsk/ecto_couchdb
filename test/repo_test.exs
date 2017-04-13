defmodule RepoTest do
  #
  # Test for the Ecto.Repository API, delegated to the CouchdbAdapter
  #
  use ExUnit.Case, async: true

  setup do
    db = DatabaseCleaner.ensure_clean_db!(Post)
    design_doc = %{_id: "_design/Post", language: "javascript",
                   views: %{
                     all: %{
                       map: "function(doc) { emit(doc._id, doc) }"
                     }
                  }}
    :couchbeam.save_doc(db, CouchdbAdapter.to_doc(design_doc))

    docs = for i <- 1..3, do: %{_id: "id#{i}", title: "t#{i}", body: "b#{i}",
                                stats: %{visits: i, time: 10*i},
                                grants: [%{user: "u#{i}.1", access: "a#{i}.1"},
                                         %{user: "u#{i}.2", access: "a#{i}.2"}]}
    for doc <- docs do
      {:ok, _} = :couchbeam.save_doc(db, CouchdbAdapter.to_doc(doc))
    end
    {:ok, pid} = Repo.start_link
    on_exit "stop repo", fn -> Process.exit(pid, :kill) end
    %{
      db: db,
      post: %Post{title: "how to write and adapter", body: "Don't know yet"},
      grants: [%Grant{user: "admin", access: "all"}, %Grant{user: "other", access: "read"}],
      docs: docs
    }
  end

  describe "insert" do
    defp has_id_and_rev?(resource) do
      assert resource._id
      assert resource._rev
    end

    test "generates id/rev", %{post: post} do
      {:ok, result} = Repo.insert(post)
      assert has_id_and_rev?(result)
    end

    test "uses locally generated id", %{post: post} do
      post = struct(post, _id: "FOO")
      {:ok, result} = Repo.insert(post)
      assert has_id_and_rev?(result)
      assert result._id == "FOO"
    end

    test "fails if using the same id twice", %{post: post} do
      post = struct(post, _id: "FOO")
      assert {:ok, _} = Repo.insert(post)
      exception = assert_raise Ecto.ConstraintError, fn -> Repo.insert(post) end
      assert exception.constraint == "posts_id_index"
    end

    test "handles conflicts as changeset errors using unique_constraint", %{post: post} do
      import Ecto.Changeset
      params = Map.from_struct(post)
      changeset = cast(%Post{}, %{ params | _id: "FOO"}, [:title, :body, :_id])
                  |> unique_constraint(:id)
      assert {:ok, _} = Repo.insert(changeset)
      assert {:error, changeset} = Repo.insert(changeset)
      assert changeset.errors[:id] != nil
      assert changeset.errors[:id] == {"has already been taken", []}
    end

    test "supports embeds", %{post: post, grants: grants} do
      post = struct(post, grants: grants)
      {:ok, result} = Repo.insert(post)
      assert has_id_and_rev?(result)
    end

    test "supports embeds without ids", %{post: post} do
      post = struct(post, stats: %Stats{visits: 12, time: 892})
      {:ok, result} = Repo.insert(post)
      assert has_id_and_rev?(result)
    end
  end

  describe "all(Schema)" do
    test "retrieves all Posts as a list", %{docs: docs} do
      results = Repo.all(Post)
      assert length(results) == length(docs)
    end

    test "reads all non-embedded properties", %{docs: docs} do
      # get results indexed by _id to remove database non-determinism
      results = Repo.all(Post) |> Enum.map(fn post -> {post._id, post} end) |> Enum.into(%{})
      # compare values for all keys in the expected against the same-id actuals
      for expected <- docs,
          actual <- [Map.get(results, expected._id)],
          {k, v} <- expected,
          k != :stats and k != :grants,
          do: assert Map.get(actual, k) == v
    end

    test "reads embeds_one properties" do
      # get results indexed by _id to remove database non-determinism
      results = Repo.all(Post) |> Enum.map(fn post -> {post._id, post} end) |> Enum.into(%{})
      assert results["id1"].stats == %Stats{time: 10, visits: 1}
      assert results["id2"].stats == %Stats{time: 20, visits: 2}
    end

    test "reads embeds_many properties" do
      # get results indexed by _id to remove database non-determinism
      results = Repo.all(Post) |> Enum.map(fn post -> {post._id, post} end) |> Enum.into(%{})
      assert results["id1"].grants == [%Grant{user: "u1.1", access: "a1.1"}, %Grant{user: "u1.2", access: "a1.2"}]
      assert results["id2"].grants == [%Grant{user: "u2.1", access: "a2.1"}, %Grant{user: "u2.2", access: "a2.2"}]
    end
  end

  describe "all(Ecto.Query)" do
    import Ecto.Query

    test "Post.all == key" do
      query = from p in Post, where: p.all == "id1"
      results = Repo.all(query)
      assert length(results) == 1
      [result] = results
      assert result._id == "id1"
    end

    test "Post.all in [keys...]" do
      query = from p in Post, where: p.all in ["id1", "id2", "not found"]
      results = Repo.all(query) |> Enum.map(fn post -> {post._id, post} end) |> Enum.into(%{})
      assert length(Map.keys(results)) == 2
    end

    test "Post.all > key is NOT SUPPORTED" do
      assert_raise RuntimeError, fn -> Repo.all(from p in Post, where: p.all > "id2") end
    end

    test "Post.all >= key" do
      query = from p in Post, where: p.all >= "id2"
      results = Repo.all(query)
      assert length(results) == 2
      [id2, id3] = results
      assert id2._id == "id2"
      assert id3._id == "id3"
    end

    test "Post.all <= key" do
      query = from p in Post, where: p.all <= "id2"
      results = Repo.all(query)
      assert length(results) == 2
      [id1, id2] = results
      assert id1._id == "id1"
      assert id2._id == "id2"
    end
  end
end
