.PHONY : clean push

push: .pyvenv
	.pyvenv/bin/python3 push.py

.pyvenv : push.py_requirements.txt
	python3 -m venv --upgrade .pyvenv
	.pyvenv/bin/pip --require-virtualenv install --upgrade -r push.py_requirements.txt
	echo .pyvenv Updated

clean :
	rm -rf .pyvenv
