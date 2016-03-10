require File.dirname(__FILE__) + '/../spec_helper'

describe PostsController, "spam" do
  let(:spammer_content) {
    p = Post.make!(parent: User.make!)
    p.user.update_attributes(spammer: true)
    p
  }
  let(:flagged_content) {
    p = Post.make!(parent: User.make!)
    Flag.make!(flaggable: p, flag: Flag::SPAM)
    p
  }

  describe "show" do
    it "should render 403 when the owner is a spammer" do
      get :show, id: spammer_content.id
      expect( response.response_code ).to eq 403
    end

    it "should render 403 when content is flagged as spam" do
      get :show, id: spammer_content.id
      expect( response.response_code ).to eq 403
    end
  end

  describe "index" do
    it "should render atom" do
      expect {
        get :index, login: spammer_content.user.login, format: :atom
      }.not_to raise_error
    end
  end
end

describe PostsController, "creation" do
  describe "for user journal" do
    let( :user ) { User.make! }
    before do
      sign_in user
    end
    it "should work for user" do
      expect {
        post :create, post: { title: "Foo", body: "Bar", parent_type: "User", parent_id: user.id }
      }.to change( Post, :count ).by( 1 )
    end
    it "should not allow a user to post to another user's journal" do
      expect {
        post :create, post: { title: "Foo", body: "Bar", parent_type: "User", parent_id: User.make!.id }
      }.not_to change( Post, :count )
    end
  end
  describe "for projects" do
    let( :user ) { User.make! }
    before do
      sign_in user
    end
    it "should work for a curator" do
      project = Project.make!( user: user )
      expect( project ).to be_curated_by user
      expect {
        post :create, post: { title: "Foo", body: "Bar", parent_type: "Project", parent_id: project.id }
      }.to change( Post, :count ).by( 1 )
    end
    it "should not work for a non-curator" do
      project = Project.make!
      expect( project ).not_to be_curated_by user
      expect {
        post :create, post: { title: "Foo", body: "Bar", parent_type: "Project", parent_id: project.id }
      }.not_to change( Post, :count )
    end
  end
  describe "for sites" do
    let( :site ) { Site.make! }
    it "should work for a site admin" do
      user = make_admin
      sign_in user
      expect {
        post :create, post: { title: "Foo", body: "Bar", parent_type: "Site", parent_id: site.id }
      }.to change( Post, :count ).by( 1 )
    end
    it "should not work for a normal user" do
      user = User.make!
      sign_in user
      expect {
        post :create, post: { title: "Foo", body: "Bar", parent_type: "Site", parent_id: site.id }
      }.not_to change( Post, :count )
    end
  end
end

describe PostsController, "update" do
  describe "for user" do
    let( :user ) { User.make! }
    before { sign_in user }
    it "should work for owner" do
      p = Post.make!( user: user, parent: user )
      new_body = "This is a new body"
      put :update, id: p.id, post: { body: new_body }
      p.reload
      expect( p.body ).to eq new_body
    end
    it "should not work for non-owner" do
      other_user = User.make!
      p = Post.make!( parent: other_user, user: other_user )
      new_body = "This is a new body"
      put :update, id: p.id, post: { body: new_body }
      p.reload
      expect( p.body ).not_to eq new_body
    end
  end
  describe "for project" do
    let( :user ) { User.make! }
    before { sign_in user }
    it "should work or a project curator" do
      project = Project.make!( user: user )
      p = Post.make!( user: user, parent: project )
      new_body = "This is a new body"
      put :update, id: p.id, post: { body: new_body }
      p.reload
      expect( p.body ).to eq new_body
    end
    it "should not work for a normal user" do
      project = Project.make!
      p = Post.make!( user: project.user, parent: project )
      new_body = "This is a new body"
      put :update, id: p.id, post: { body: new_body }
      p.reload
      expect( p.body ).not_to eq new_body
    end
  end
  describe "for site" do
    it "should work or a site admin" do
      site = Site.make!
      user = make_admin
      sign_in user
      p = Post.make!( parent: site )
      new_body = "This is a new body"
      put :update, id: p.id, post: { body: new_body }
      p.reload
      expect( p.body ).to eq new_body
    end
    it "should not work for a normal user" do
      site = Site.make!
      user = User.make!
      sign_in user
      p = Post.make!( parent: site )
      new_body = "This is a new body"
      put :update, id: p.id, post: { body: new_body }
      p.reload
      expect( p.body ).not_to eq new_body
    end
  end
end

describe PostsController, "for projects" do
  let(:project) { Project.make! }
  describe "edit" do
    let(:post) { Post.make!(parent: project, user: project.user) }
    def expect_post_to_be_editable_by(user)
      sign_in user
      get :edit, id: post.id
      expect( response.response_code ).to eq 200
    end
    it "should work for post author" do
      expect_post_to_be_editable_by post.user
    end
    it "should work for project managers" do
      pu = ProjectUser.make!(project: project, role: ProjectUser::MANAGER)
      expect_post_to_be_editable_by pu.user
    end
    it "should work for project curators" do
      pu = ProjectUser.make!(project: project, role: ProjectUser::CURATOR)
      expect_post_to_be_editable_by pu.user
    end
  end
end
