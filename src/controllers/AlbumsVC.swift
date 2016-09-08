// AlbumsVC.swift
// Copyright (c) 2016 Nyx0uf
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.


import UIKit


final class AlbumsVC : UITableViewController
{
	// MARK: - Private properties
	// Selected artist
	var artist: Artist!
	// Label in the navigationbar
	private var titleView: UILabel! = nil
	// Keep track of download operations to eventually cancel them
	private var _downloadOperations = [String : Operation]()

	// MARK: - Initializers
	required init?(coder aDecoder: NSCoder)
	{
		self.artist = nil
		super.init(coder:aDecoder)
	}

	// MARK: - UIViewController
	override func viewDidLoad()
	{
		super.viewDidLoad()
		// Remove back button label
		navigationItem.backBarButtonItem = UIBarButtonItem(title:"", style:.plain, target:nil, action:nil)

		// Tableview
		tableView.tableFooterView = UIView()

		// Navigation bar title
		titleView = UILabel(frame:CGRect(CGPoint.zero, 100.0, 44.0))
		titleView.numberOfLines = 2
		titleView.textAlignment = .center
		titleView.isAccessibilityElement = false
		titleView.textColor = navigationController?.navigationBar.tintColor
		titleView.backgroundColor = navigationController?.navigationBar.barTintColor
		navigationItem.titleView = titleView
	}

	override func viewWillAppear(_ animated: Bool)
	{
		super.viewWillAppear(animated)

		if artist.albums.count <= 0
		{
			MPDDataSource.shared.getAlbumsForArtist(artist) {
				DispatchQueue.main.async {
					self.tableView.reloadData()
					self._updateNavigationTitle()
				}
			}
		}

		_updateNavigationTitle()
	}

	override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask
	{
		return .portrait
	}

	override func preferredStatusBarStyle() -> UIStatusBarStyle
	{
		return .lightContent
	}

	override func prepare(for segue: UIStoryboardSegue, sender: AnyObject?)
	{
		if segue.identifier == "albums-to-albumdetail"
		{
			let vc = segue.destinationViewController as! AlbumDetailVC
			vc.selectedIndex = tableView.indexPathForSelectedRow!.row
			vc.albums = artist.albums
		}
	}

	// MARK: - Private
	private func _updateNavigationTitle()
	{
		let attrs = NSMutableAttributedString(string:artist.name + "\n", attributes:[NSFontAttributeName : UIFont(name:"HelveticaNeue-Medium", size:14.0)!])
		attrs.append(AttributedString(string:"\(artist.albums.count) \(artist.albums.count > 1 ? NYXLocalizedString("lbl_albums").lowercased() : NYXLocalizedString("lbl_album").lowercased())", attributes:[NSFontAttributeName : UIFont(name:"HelveticaNeue", size:13.0)!]))
		titleView.attributedText = attrs
	}
}

// MARK: - UITableViewDataSource
extension AlbumsVC
{
	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
	{
		return artist.albums.count + 1 // dummy
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
	{
		let cell = tableView.dequeueReusableCell(withIdentifier: "io.whine.mpdremote.cell.album", for:indexPath) as! AlbumTableViewCell

		// Dummy to let some space for the mini player
		if indexPath.row == artist.albums.count
		{
			cell.coverView.image = nil
			cell.lblAlbum.text = ""
			cell.separator.isHidden = true
			cell.accessoryType = .none
			cell.selectionStyle = .none
			return cell
		}

		let album = artist.albums[indexPath.row]
		cell.lblAlbum.text = album.name
		cell.separator.isHidden = false
		cell.accessoryType = .disclosureIndicator
		cell.accessibilityLabel = "\(album.name)"

		// No server for covers
		if UserDefaults.standard().data(forKey: kNYXPrefWEBServer) == nil
		{
			cell.coverView.image = generateCoverForAlbum(album, size: cell.coverView.size)
			return cell
		}

		// Get local URL for cover
		guard let coverURL = album.localCoverURL else
		{
			Logger.alog("[!] No cover URL for \(album)") // should not happen
			cell.coverView.image = generateCoverForAlbum(album, size: cell.coverView.size)
			return cell
		}

		if let cover = UIImage.loadFromURL(coverURL)
		{
			DispatchQueue.global(attributes: DispatchQueue.GlobalAttributes.qosUserInitiated).async {
				let cropped = cover.imageCroppedToFitSize(cell.coverView.size)
				DispatchQueue.main.async {
					if let c = self.tableView.cellForRow(at: indexPath) as? AlbumTableViewCell
					{
						c.coverView.image = cropped
					}
				}
			}
		}
		else
		{
			cell.coverView.image = generateCoverForAlbum(album, size: cell.coverView.size)
			let sizeAsData = UserDefaults.standard().data(forKey: kNYXPrefCoverSize)!
			let cropSize = NSKeyedUnarchiver.unarchiveObject(with: sizeAsData) as! NSValue
			if album.path != nil
			{
				_downloadCoverForAlbum(album, cropSize:cropSize.cgSizeValue()) { (thumbnail: UIImage) in
					let cropped = thumbnail.imageCroppedToFitSize(cell.coverView.size)
					DispatchQueue.main.async {
						if let c = self.tableView.cellForRow(at: indexPath) as? AlbumTableViewCell
						{
							c.coverView.image = cropped
						}
					}
				}
			}
			else
			{
				MPDDataSource.shared.getPathForAlbum(album) {
					self._downloadCoverForAlbum(album, cropSize:cropSize.cgSizeValue()) { (thumbnail: UIImage) in
						let cropped = thumbnail.imageCroppedToFitSize(cell.coverView.size)
						DispatchQueue.main.async {
							if let c = self.tableView.cellForRow(at: indexPath) as? AlbumTableViewCell
							{
								c.coverView.image = cropped
							}
						}
					}
				}
			}
		}

		return cell
	}

	private func _downloadCoverForAlbum(_ album: Album, cropSize: CGSize, callback:(thumbnail: UIImage) -> Void)
	{
		let downloadOperation = CoverOperation(album:album, cropSize:cropSize)
		let key = album.name + album.year
		weak var weakOperation = downloadOperation
		downloadOperation.cplBlock = {(cover: UIImage, thumbnail: UIImage) in
			if let op = weakOperation
			{
				if !op.isCancelled
				{
					self._downloadOperations.removeValue(forKey: key)
				}
			}
			callback(thumbnail:thumbnail)
		}
		_downloadOperations[key] = downloadOperation
		APP_DELEGATE().operationQueue.addOperation(downloadOperation)
	}
}

// MARK: - UITableViewDelegate
extension AlbumsVC
{
	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
	{
		// Dummy, ignore
		if indexPath.row == artist.albums.count
		{
			return
		}

		performSegue(withIdentifier: "albums-to-albumdetail", sender: self)
	}
	
	override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath)
	{
		// Dummy, ignore
		if indexPath.row == artist.albums.count
		{
			return
		}

		// Remove download cover operation if still in queue
		let album = artist.albums[indexPath.row]
		let key = album.name + album.year
		if let op = _downloadOperations[key] as! CoverOperation?
		{
			op.cancel()
			_downloadOperations.removeValue(forKey: key)
			Logger.dlog("[+] Cancelling \(op)")
		}
	}

	override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat
	{
		if indexPath.row == artist.albums.count
		{
			return 44.0 // dummy cell
		}
		return 74.0
	}
}
